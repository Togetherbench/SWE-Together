#!/bin/bash
set +e

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

write_reward() {
    printf "%.4f\n" "$1" > /logs/verifier/reward.txt
}

# Locate repo
REPO_DIR=""
for d in /workspace/pi-mono /workspace/repo /workspace; do
  if [ -f "$d/packages/tui/src/autocomplete.ts" ]; then
    REPO_DIR="$d"
    break
  fi
done

if [ -z "$REPO_DIR" ]; then
  emit p2p_changelog_structure_intact false "repo not found"
  emit t1_f2p_changelog_unreleased_grew false "repo not found"
  emit t1_f2p_changelog_attribution_format false "repo not found"
  emit t7_f2p_autocomplete_dir_no_trailing_space false "repo not found"
  emit t7_f2p_autocomplete_dir_marker false "repo not found"
  write_reward 0
  exit 0
fi

cd "$REPO_DIR"
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

AI_CL="packages/ai/CHANGELOG.md"
TUI_CL="packages/tui/CHANGELOG.md"
CA_CL="packages/coding-agent/CHANGELOG.md"
AUTOCOMPLETE_FILE="packages/tui/src/autocomplete.ts"

###############################################################################
# Capture baseline [Unreleased] entry counts
###############################################################################
BASELINE_DIR="/baseline/changelog_snap"
mkdir -p "$BASELINE_DIR"

count_unreleased_bullets() {
  local f="$1"
  if [ ! -f "$f" ]; then echo 0; return; fi
  # Extract the [Unreleased] section: from "## [Unreleased]" to next "## ["
  awk '
    /^## \[Unreleased\]/ {flag=1; next}
    /^## \[/ && flag {flag=0}
    flag {print}
  ' "$f" | grep -cE '^[[:space:]]*-[[:space:]]+'
}

# If baselines from a prior pre-task snapshot don't exist, snapshot from
# git HEAD (which should still be the buggy/initial state at verify time
# only if the agent didn't commit; otherwise fall back to 0).
get_baseline_count() {
  local pkg="$1" file="$2"
  local snap="$BASELINE_DIR/${pkg}_unreleased_count"
  if [ -f "$snap" ]; then
    cat "$snap"
    return
  fi
  # Try git show HEAD~? – just use the file at HEAD's first parent that the
  # task started from. Use original-state approximation: read from git's
  # initial index. If unavailable, assume 0 (any addition counts).
  if [ -d ".git" ] && git cat-file -e "HEAD:$file" 2>/dev/null; then
    git show "HEAD:$file" 2>/dev/null | awk '
      /^## \[Unreleased\]/ {flag=1; next}
      /^## \[/ && flag {flag=0}
      flag {print}
    ' | grep -cE '^[[:space:]]*-[[:space:]]+'
  else
    echo 0
  fi
}

AI_BASE=$(get_baseline_count ai "$AI_CL")
TUI_BASE=$(get_baseline_count tui "$TUI_CL")
CA_BASE=$(get_baseline_count coding-agent "$CA_CL")

AI_NOW=$(count_unreleased_bullets "$AI_CL")
TUI_NOW=$(count_unreleased_bullets "$TUI_CL")
CA_NOW=$(count_unreleased_bullets "$CA_CL")

###############################################################################
# P2P: changelogs structurally valid
###############################################################################
P2P_OK=1
for f in "$AI_CL" "$TUI_CL" "$CA_CL"; do
  if [ ! -f "$f" ]; then P2P_OK=0; break; fi
  if ! grep -qE '^## \[' "$f"; then P2P_OK=0; break; fi
done
if [ "$P2P_OK" = "1" ]; then
  emit p2p_changelog_structure_intact true ""
else
  emit p2p_changelog_structure_intact false "missing or malformed CHANGELOG"
fi

###############################################################################
# t1_f2p_changelog_unreleased_grew: at least two changelogs gained entries
###############################################################################
GROWN=0
[ "$AI_NOW" -gt "$AI_BASE" ] && GROWN=$((GROWN+1))
[ "$TUI_NOW" -gt "$TUI_BASE" ] && GROWN=$((GROWN+1))
[ "$CA_NOW" -gt "$CA_BASE" ] && GROWN=$((GROWN+1))

if [ "$GROWN" -ge 2 ]; then
  emit t1_f2p_changelog_unreleased_grew true "ai:${AI_BASE}->${AI_NOW} tui:${TUI_BASE}->${TUI_NOW} ca:${CA_BASE}->${CA_NOW}"
  GATE_T1A=1
else
  emit t1_f2p_changelog_unreleased_grew false "only $GROWN changelogs grew (ai:${AI_BASE}->${AI_NOW} tui:${TUI_BASE}->${TUI_NOW} ca:${CA_BASE}->${CA_NOW})"
  GATE_T1A=0
fi

###############################################################################
# t1_f2p_changelog_attribution_format:
# Only inspect bullets that were ADDED (i.e., bullets present now but not
# in the baseline [Unreleased]). For each such bullet, require canonical
# attribution: ([#N](https://github.com/badlogic/pi-mono/(issues|pull)/N)
# optionally " by [@user](https://github.com/user)").
###############################################################################
TMP_NEW=$(mktemp)
: > "$TMP_NEW"

extract_unreleased_bullets() {
  local content="$1"
  echo "$content" | awk '
    /^## \[Unreleased\]/ {flag=1; next}
    /^## \[/ && flag {flag=0}
    flag && /^[[:space:]]*-[[:space:]]+/ {print}
  '
}

for pkg_file in "$AI_CL" "$TUI_CL" "$CA_CL"; do
  [ -f "$pkg_file" ] || continue
  current=$(cat "$pkg_file")
  if [ -d ".git" ] && git cat-file -e "HEAD:$pkg_file" 2>/dev/null; then
    baseline=$(git show "HEAD:$pkg_file" 2>/dev/null)
  else
    baseline=""
  fi
  cur_bullets=$(extract_unreleased_bullets "$current")
  base_bullets=$(extract_unreleased_bullets "$baseline")
  # Output bullets in current that aren't in baseline (line-wise)
  if [ -z "$base_bullets" ]; then
    echo "$cur_bullets" >> "$TMP_NEW"
  else
    # diff -based comparison
    diff <(echo "$base_bullets") <(echo "$cur_bullets") | grep '^>' | sed 's/^> //' >> "$TMP_NEW"
  fi
done

ATTRIB_PATTERN='\(\[#[0-9]+\]\(https://github\.com/badlogic/pi-mono/(issues|pull)/[0-9]+\)( by \[@[^]]+\]\(https://github\.com/[^)]+\))?\)'
NEW_BULLETS=$(grep -cE '^[[:space:]]*-[[:space:]]+' "$TMP_NEW" 2>/dev/null || echo 0)
ATTRIBUTED=$(grep -cE "$ATTRIB_PATTERN" "$TMP_NEW" 2>/dev/null || echo 0)

if [ "$NEW_BULLETS" -ge 2 ] && [ "$ATTRIBUTED" -ge 2 ]; then
  emit t1_f2p_changelog_attribution_format true "new=${NEW_BULLETS} attributed=${ATTRIBUTED}"
  GATE_T1B=1
else
  emit t1_f2p_changelog_attribution_format false "new=${NEW_BULLETS} attributed=${ATTRIBUTED}"
  GATE_T1B=0
fi
rm -f "$TMP_NEW"

###############################################################################
# T7 autocomplete behavioral test:
# Strategy: build a sandbox dir tree and *execute* the autocomplete module to
# obtain its results. We try multiple invocation surfaces (named exports vary
# by patch). If the module exports a function that returns AutocompleteItem-
# like objects, inspect them. Otherwise fall back to behaviorally simulating
# how the editor would use the output: a directory entry must be detectable
# (trailing '/' or isDirectory:true) AND must NOT yield a trailing space when
# applied.
###############################################################################

# Build sandbox
SBX=$(mktemp -d)
mkdir -p "$SBX/src/components"
mkdir -p "$SBX/packages/tui/src"
mkdir -p "$SBX/docs"
echo "x" > "$SBX/README.md"
echo "y" > "$SBX/src/index.ts"
echo "z" > "$SBX/src/components/button.ts"
echo "w" > "$SBX/packages/tui/src/autocomplete.ts"

GATE_T7A=0
GATE_T7B=0

# Find a TS runner
TS_RUNNER=""
if command -v tsx >/dev/null 2>&1; then
  TS_RUNNER="tsx"
elif command -v bun >/dev/null 2>&1; then
  TS_RUNNER="bun"
elif command -v npx >/dev/null 2>&1; then
  if npx --no-install tsx --version >/dev/null 2>&1; then
    TS_RUNNER="npx --no-install tsx"
  fi
fi

# Try to discover within the repo (workspace deps)
if [ -z "$TS_RUNNER" ] && [ -x "$REPO_DIR/node_modules/.bin/tsx" ]; then
  TS_RUNNER="$REPO_DIR/node_modules/.bin/tsx"
fi

PROBE_OUT=$(mktemp)

if [ -n "$TS_RUNNER" ]; then
  PROBE_TS=$(mktemp --suffix=.mjs)
  cat > "$PROBE_TS" <<'PROBE'
// Behavioral probe of autocomplete.ts
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const modPath = process.argv[2];
const sandbox = process.argv[3];

process.chdir(sandbox);

let mod;
try {
  mod = await import(pathToFileURL(resolve(modPath)).href);
} catch (e) {
  console.log(JSON.stringify({ error: 'import_failed', message: String(e && e.message || e) }));
  process.exit(0);
}

// Collect candidate functions
const fns = [];
for (const [k, v] of Object.entries(mod)) {
  if (typeof v === 'function') fns.push([k, v]);
}

// Try common names first
const preferred = ['fileAutocomplete', 'getFileCompletions', 'autocomplete',
                   'completePath', 'completeFile', 'fileCompletions',
                   'getCompletions', 'default'];
fns.sort((a, b) => {
  const ai = preferred.indexOf(a[0]); const bi = preferred.indexOf(b[0]);
  return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
});

const queries = ['', 'src', 'src/', 'doc', 'packages'];
const results = {};

for (const [name, fn] of fns) {
  for (const q of queries) {
    for (const args of [[q], [q, sandbox], [q, { cwd: sandbox }], [{ query: q, cwd: sandbox }]]) {
      try {
        let out = fn.apply(null, args);
        if (out && typeof out.then === 'function') out = await out;
        if (Array.isArray(out) && out.length) {
          results[`${name}::${q}::${args.length}`] = out.slice(0, 50);
        }
      } catch (e) { /* swallow */ }
    }
  }
}

console.log(JSON.stringify({ exports: Object.keys(mod), fns: fns.map(f => f[0]), results }));
PROBE

  $TS_RUNNER "$PROBE_TS" "$REPO_DIR/$AUTOCOMPLETE_FILE" "$SBX" > "$PROBE_OUT" 2>/dev/null
  rm -f "$PROBE_TS"
fi

# Analyze probe output (if any) with node
ANALYSIS=$(node -e '
const fs = require("fs");
const path = process.argv[1];
let data = {};
try { data = JSON.parse(fs.readFileSync(path, "utf8")); } catch { data = {}; }
const results = data.results || {};

let dirSeen = false;          // any result identifiable as a directory
let dirNoTrailingSpace = false;
let fileSeen = false;
let dirHasMarker = false;     // dir distinguishable from file (slash or flag)

const isDirEntry = (e) => {
  if (!e) return false;
  if (typeof e === "string") return e.endsWith("/");
  if (e.isDirectory === true) return true;
  if (e.type === "directory" || e.type === "dir") return true;
  for (const k of ["path", "value", "completion", "label", "text", "insertText", "name"]) {
    if (typeof e[k] === "string" && e[k].endsWith("/")) return true;
  }
  return false;
};

const getInsert = (e) => {
  if (typeof e === "string") return e;
  if (!e || typeof e !== "object") return "";
  for (const k of ["insertText", "value", "completion", "path", "text", "label", "name"]) {
    if (typeof e[k] === "string") return e[k];
  }
  return "";
};

for (const [k, arr] of Object.entries(results)) {
  for (const item of arr) {
    if (isDirEntry(item)) {
      dirSeen = true;
      const ins = getInsert(item);
      if (ins.endsWith("/") || (typeof item === "object" && item.isDirectory === true)) {
        dirHasMarker = true;
      }
      // Should NOT end with " " (space) and SHOULD NOT carry an `appendSpace:true`-style flag
      const endsWithSpace = ins.endsWith(" ");
      const flagsSpace = (typeof item === "object" && (item.appendSpace === true || item.suffix === " " || item.trailingSpace === true));
      if (!endsWithSpace && !flagsSpace) dirNoTrailingSpace = true;
    } else {
      fileSeen = true;
    }
  }
}

console.log(JSON.stringify({ dirSeen, dirNoTrailingSpace, dirHasMarker, fileSeen, hasResults: Object.keys(results).length > 0 }));
' "$PROBE_OUT" 2>/dev/null)

# Parse analysis
DIR_SEEN=$(echo "$ANALYSIS" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).dirSeen?1:0)}catch{console.log(0)}})' 2>/dev/null)
DIR_NO_SPACE=$(echo "$ANALYSIS" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).dirNoTrailingSpace?1:0)}catch{console.log(0)}})' 2>/dev/null)
DIR_MARKER=$(echo "$ANALYSIS" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).dirHasMarker?1:0)}catch{console.log(0)}})' 2>/dev/null)
HAS_RESULTS=$(echo "$ANALYSIS" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{console.log(JSON.parse(s).hasResults?1:0)}catch{console.log(0)}})' 2>/dev/null)

DIR_SEEN=${DIR_SEEN:-0}
DIR_NO_SPACE=${DIR_NO_SPACE:-0}
DIR_MARKER=${DIR_MARKER:-0}
HAS_RESULTS=${HAS_RESULTS:-0}

###############################################################################
# Behavioral fallback / additional test: read source AND require BEHAVIORAL
# evidence — i.e., the autocomplete module must, when invoked, produce
# directory completions distinguishable from files by structural data
# (NOT just by virtue of comments). We also require that no path the
# editor would consume carries a trailing-space marker.
#
# To AVOID being satisfied by a pure no-op (which on the buggy base also
# does not append a literal trailing space in the data — the space comes
# from the editor), we additionally require that the autocomplete result
# AT MINIMUM marks directories distinctly. The buggy base does NOT do this.
###############################################################################

# Additional source-AST check (anti-decoration): the directory marker logic
# must execute (not be in a comment). We compile the file and check that the
# string "/" is concatenated/appended in the entry-construction path
# conditionally (i.e., there's an `if` branch that references `isDirectory`
# or stat-like check AND a "/" template/concat in the same conditional).
SOURCE_HAS_RUNTIME_DIR_LOGIC=0
node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
// strip comments
const stripped = src
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/(^|[^:])\/\/[^\n]*/g, "$1");

// Need both a directory predicate and a slash emission, both outside comments
const hasPredicate = /(isDirectory\s*\(\s*\)|statSync|lstatSync|\.endsWith\(\s*[`"\x27]\/[`"\x27]\s*\)|type\s*[:=]\s*[`"\x27]dir|isDir\b|kind\s*[:=]\s*[`"\x27](?:dir|directory))/.test(stripped);
const hasSlashEmit = /[`"\x27]\/[`"\x27]|\$\{[^}]*\}\/`|\+\s*[`"\x27]\/[`"\x27]/.test(stripped);
process.exit(hasPredicate && hasSlashEmit ? 0 : 1);
' "$REPO_DIR/$AUTOCOMPLETE_FILE" 2>/dev/null
if [ $? -eq 0 ]; then
  SOURCE_HAS_RUNTIME_DIR_LOGIC=1
fi

# Decision rules:
# Gate T7A (no trailing space for dirs): require either
#   (behavioral) DIR_SEEN=1 AND DIR_NO_SPACE=1 AND DIR_MARKER=1
#   OR — if module couldn't be imported but source shows runtime dir logic:
#   SOURCE_HAS_RUNTIME_DIR_LOGIC=1 AND we also detect a runtime check below.
#
# We REQUIRE a behavioral signal somewhere. If module import failed entirely
# (HAS_RESULTS=0), we still need to detect that the change is non-decorative:
# we re-import the module's text via a Function() to ensure the file at
# minimum parses as JS/TS-ish (transpile via tsx already attempted).

if [ "$HAS_RESULTS" = "1" ]; then
  if [ "$DIR_SEEN" = "1" ] && [ "$DIR_NO_SPACE" = "1" ]; then
    emit t7_f2p_autocomplete_dir_no_trailing_space true "behavioral: dir entry produced w/o trailing space"
    GATE_T7A=1
  else
    emit t7_f2p_autocomplete_dir_no_trailing_space false "behavioral run: dirSeen=$DIR_SEEN noSpace=$DIR_NO_SPACE"
  fi

  if [ "$DIR_MARKER" = "1" ] && [ "$SOURCE_HAS_RUNTIME_DIR_LOGIC" = "1" ]; then
    emit t7_f2p_autocomplete_dir_marker true "dir distinguishable in output AND runtime logic present"
    GATE_T7B=1
  else
    emit t7_f2p_autocomplete_dir_marker false "marker=$DIR_MARKER runtime=$SOURCE_HAS_RUNTIME_DIR_LOGIC"
  fi
else
  # Could not behaviorally invoke. Fall back to a stricter source signal:
  # require runtime dir logic AND require the file's exports to be importable
  # by Node (rules out broken-but-keyword-bearing patches). Without behavioral
  # output we conservatively FAIL both gates — this preserves no-op=0 and
  # only rewards patches that produce observable behavior.
  emit t7_f2p_autocomplete_dir_no_trailing_space false "could not invoke autocomplete module behaviorally"
  emit t7_f2p_autocomplete_dir_marker false "could not invoke autocomplete module behaviorally"
fi

rm -f "$PROBE_OUT"
rm -rf "$SBX"

###############################################################################
# Compute reward
###############################################################################
REWARD=0

# P2P gating
P2P_PASS=1
grep -q '"id":"p2p_changelog_structure_intact","passed":true' "$GATES_FILE" || P2P_PASS=0

if [ "$P2P_PASS" = "1" ]; then
  [ "$GATE_T1A" = "1" ] && REWARD=$(awk "BEGIN{print $REWARD + 0.25}")
  [ "$GATE_T1B" = "1" ] && REWARD=$(awk "BEGIN{print $REWARD + 0.25}")
  [ "$GATE_T7A" = "1" ] && REWARD=$(awk "BEGIN{print $REWARD + 0.30}")
  [ "$GATE_T7B" = "1" ] && REWARD=$(awk "BEGIN{print $REWARD + 0.20}")
fi

write_reward "$REWARD"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3BpLW1vbm8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_771580d1 'npm_typecheck_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_816994b6 'vitest_session_manager_ai' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/ai && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'
run_v043_gate p2p_upstream_e395cbc7 'npm_typecheck_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx tsgo --noEmit -p tsconfig.build.json 2>&1 | tail -5; rc=$?; if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then exit $rc; fi'
run_v043_gate p2p_upstream_522628b0 'vitest_session_manager_coding-agent' 'cd /workspace/pi-mono && cd /workspace/pi-mono/packages/coding-agent && timeout 120 npx vitest run test/path-utils.test.ts --reporter=basic 2>&1 | tail -10'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_changelog_attribution_format": 0.25, "t1_f2p_changelog_unreleased_grew": 0.25, "t7_f2p_autocomplete_dir_marker": 0.2, "t7_f2p_autocomplete_dir_no_trailing_space": 0.3}
P2P_GATING = ["p2p_changelog_structure_intact"]
P2P_REGRESSION = ["p2p_upstream_771580d1", "p2p_upstream_816994b6", "p2p_upstream_e395cbc7", "p2p_upstream_522628b0"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
# P2P_REGRESSION_INFORMATIONAL: only P2P_GATING items hard-zero. P2P_REGRESSION is informational.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
for gid in P2P_GATING:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0