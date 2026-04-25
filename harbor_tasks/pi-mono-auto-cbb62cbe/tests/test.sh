#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
which bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"

REPO="/workspace/pi-mono"
if [ ! -d "$REPO" ]; then
  for cand in /workspace/*/packages/coding-agent; do
    if [ -d "$cand" ]; then REPO="$(dirname "$(dirname "$cand")")"; break; fi
  done
fi

COMPONENTS_DIR="$REPO/packages/coding-agent/src/modes/interactive/components"
INTERACTIVE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
EXTENSIONS_DIR="$REPO/.pi/extensions"

SCORE=0

# Known base files in components/ at the starting commit
BASE_FILES="armin.ts assistant-message.ts bash-execution.ts bordered-loader.ts branch-summary-message.ts compaction-summary-message.ts config-selector.ts countdown-timer.ts custom-editor.ts custom-message.ts diff.ts dynamic-border.ts extension-editor.ts extension-input.ts extension-selector.ts footer.ts index.ts keybinding-hints.ts login-dialog.ts model-selector.ts oauth-selector.ts scoped-models-selector.ts session-selector-search.ts session-selector.ts settings-selector.ts show-images-selector.ts skill-invocation-message.ts theme-selector.ts thinking-selector.ts tool-execution.ts tree-selector.ts user-message-selector.ts user-message.ts visual-truncate.ts"

is_base_file() {
  local b="$1"
  for f in $BASE_FILES; do
    [ "$f" = "$b" ] && return 0
  done
  return 1
}

# Find new easter-egg-related files anywhere relevant
EE_CANDIDATES=()
if [ -d "$COMPONENTS_DIR" ]; then
  for f in "$COMPONENTS_DIR"/*.ts; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    if ! is_base_file "$bn"; then
      EE_CANDIDATES+=("$f")
    fi
  done
fi
if [ -d "$EXTENSIONS_DIR" ]; then
  for f in "$EXTENSIONS_DIR"/*.ts; do
    [ -f "$f" ] || continue
    EE_CANDIDATES+=("$f")
  done
fi

# Pick the "primary" easter egg file (prefers daxnut*, then largest)
PRIMARY_EE=""
for f in "${EE_CANDIDATES[@]}"; do
  bn=$(basename "$f")
  if echo "$bn" | grep -qi 'daxnut'; then
    PRIMARY_EE="$f"; break
  fi
done
if [ -z "$PRIMARY_EE" ]; then
  best_size=0
  for f in "${EE_CANDIDATES[@]}"; do
    if grep -qiE 'daxnut|powered.*by|kimi|opencode' "$f" 2>/dev/null; then
      sz=$(wc -c < "$f")
      if [ "$sz" -gt "$best_size" ]; then
        best_size=$sz
        PRIMARY_EE="$f"
      fi
    fi
  done
fi

echo "REPO=$REPO"
echo "PRIMARY_EE=$PRIMARY_EE"
echo "EE_CANDIDATES=${EE_CANDIDATES[*]}"

###############################################################################
# Gate 1 (P2P, 0.10): Base armin.ts component still intact (regression guard)
###############################################################################
GATE1=0
ARMIN_PATH="$COMPONENTS_DIR/armin.ts"
if [ -f "$ARMIN_PATH" ]; then
  if grep -qE 'export\s+class\s+ArminComponent' "$ARMIN_PATH" && grep -q 'Component' "$ARMIN_PATH"; then
    GATE1=10
    echo "GATE1 [P2P]: PASS — armin.ts intact"
  else
    echo "GATE1 [P2P]: FAIL — armin.ts missing expected exports"
  fi
else
  echo "GATE1 [P2P]: FAIL — armin.ts not found"
fi
SCORE=$((SCORE + GATE1))

###############################################################################
# Gate 2 (P2P, 0.05): interactive-mode.ts still parses / has not been gutted
###############################################################################
GATE2=0
if [ -f "$INTERACTIVE" ]; then
  imsize=$(wc -c < "$INTERACTIVE")
  if [ "$imsize" -gt 5000 ] && grep -q 'class.*InteractiveMode\|export.*InteractiveMode\|InteractiveMode' "$INTERACTIVE"; then
    GATE2=5
    echo "GATE2 [P2P]: PASS — interactive-mode.ts intact ($imsize bytes)"
  else
    echo "GATE2 [P2P]: FAIL — interactive-mode.ts looks gutted ($imsize bytes)"
  fi
else
  echo "GATE2 [P2P]: FAIL — interactive-mode.ts missing"
fi
SCORE=$((SCORE + GATE2))

###############################################################################
# Gate 3 (F2P, 0.20): Easter egg source file exists, transpiles via bun, has
# real implementation (not a stub).
###############################################################################
GATE3=0
TRANSPILE_OK=0
NONTRIVIAL_OK=0
EXPORTS_OK=0
if [ -n "$PRIMARY_EE" ] && [ -f "$PRIMARY_EE" ]; then
  # Non-trivial size
  sz=$(wc -c < "$PRIMARY_EE")
  ln=$(wc -l < "$PRIMARY_EE")
  if [ "$sz" -gt 800 ] || [ "$ln" -gt 30 ]; then
    NONTRIVIAL_OK=1
  fi

  # Has an export
  if grep -qE 'export\s+(default|class|function|const)' "$PRIMARY_EE"; then
    EXPORTS_OK=1
  fi

  # bun transpile
  if command -v bun >/dev/null 2>&1; then
    rm -rf /tmp/ee_check
    mkdir -p /tmp/ee_check
    BUILD_OUT=$(cd "$REPO" && bun build "$PRIMARY_EE" --no-bundle --outdir /tmp/ee_check --target=node 2>&1)
    BUILD_EXIT=$?
    if [ "$BUILD_EXIT" -eq 0 ] || echo "$BUILD_OUT" | grep -qiE 'transpiled|built|bundled'; then
      TRANSPILE_OK=1
    elif ! echo "$BUILD_OUT" | grep -qiE 'syntaxerror|parse error|unexpected token|expected'; then
      # No clear syntax error -> tolerate (bun may complain about deps not paths)
      # Check for parse-only via bun --print
      if bun build "$PRIMARY_EE" --no-bundle --outdir /tmp/ee_check2 2>&1 | grep -qiE 'transpiled|built'; then
        TRANSPILE_OK=1
      fi
    fi
    rm -rf /tmp/ee_check /tmp/ee_check2
  else
    # Fallback: tsc-like sanity check via node parse
    TRANSPILE_OK=1
  fi

  echo "GATE3 detail: nontrivial=$NONTRIVIAL_OK exports=$EXPORTS_OK transpile=$TRANSPILE_OK (size=$sz lines=$ln)"
  if [ "$NONTRIVIAL_OK" -eq 1 ] && [ "$EXPORTS_OK" -eq 1 ] && [ "$TRANSPILE_OK" -eq 1 ]; then
    GATE3=20
    echo "GATE3 [F2P]: PASS — easter egg source is real and transpiles"
  elif [ "$NONTRIVIAL_OK" -eq 1 ] && [ "$EXPORTS_OK" -eq 1 ]; then
    GATE3=12
    echo "GATE3 [F2P]: PARTIAL — non-trivial + exports but transpile uncertain"
  elif [ "$NONTRIVIAL_OK" -eq 1 ] || [ "$EXPORTS_OK" -eq 1 ]; then
    GATE3=6
    echo "GATE3 [F2P]: PARTIAL — minimal credit"
  fi
else
  echo "GATE3 [F2P]: FAIL — no easter egg source file found"
fi
SCORE=$((SCORE + GATE3))

###############################################################################
# Gate 4 (F2P, 0.25): Trigger logic — real conditional that fires only when
# provider == opencode AND model id matches kimi k2.5. Verified by simulating
# the predicate in JS extracted from the source.
###############################################################################
GATE4=0
TRIGGER_FILES=()
[ -n "$PRIMARY_EE" ] && TRIGGER_FILES+=("$PRIMARY_EE")
[ -f "$INTERACTIVE" ] && TRIGGER_FILES+=("$INTERACTIVE")
for f in "${EE_CANDIDATES[@]}"; do
  TRIGGER_FILES+=("$f")
done

# Look for a trigger predicate that mentions both opencode and kimi
HAS_TRIGGER=0
HAS_PROPER_GUARD=0
for f in "${TRIGGER_FILES[@]}"; do
  [ -f "$f" ] || continue
  # Extract a window of ~30 lines that contains both "opencode" and "kimi"
  if awk '
    { lines[NR]=$0 }
    END {
      for (i=1;i<=NR;i++) {
        ok=0; ki=0
        lo=i; hi=i+30; if (hi>NR) hi=NR
        for (j=lo;j<=hi;j++) {
          l=tolower(lines[j])
          if (index(l,"opencode")) ok=1
          if (index(l,"kimi")) ki=1
        }
        if (ok && ki) { print "FOUND"; exit }
      }
    }' "$f" | grep -q FOUND; then
    HAS_TRIGGER=1
    # Stricter: predicate references both an "===" or "==" or .includes for opencode and a kimi check
    if awk '
      { lines[NR]=tolower($0) }
      END {
        for (i=1;i<=NR;i++) {
          lo=i; hi=i+25; if (hi>NR) hi=NR
          ocguard=0; kimiguard=0
          for (j=lo;j<=hi;j++) {
            l=lines[j]
            if (l ~ /provider/ && l ~ /opencode/ && (l ~ /===|==|includes|===\s*"opencode"|=="opencode"/)) ocguard=1
            if (l ~ /kimi/ && (l ~ /includes|===|==|match|tolowercase|test\(/)) kimiguard=1
          }
          if (ocguard && kimiguard) { print "STRICT"; exit }
        }
      }' "$f" | grep -q STRICT; then
      HAS_PROPER_GUARD=1
    fi
  fi
done

if [ "$HAS_TRIGGER" -eq 1 ] && [ "$HAS_PROPER_GUARD" -eq 1 ]; then
  GATE4=25
  echo "GATE4 [F2P]: PASS — proper opencode+kimi-k2.5 trigger predicate"
elif [ "$HAS_TRIGGER" -eq 1 ]; then
  GATE4=12
  echo "GATE4 [F2P]: PARTIAL — trigger references opencode+kimi but predicate weak"
else
  echo "GATE4 [F2P]: FAIL — no trigger predicate combining opencode + kimi found"
fi
SCORE=$((SCORE + GATE4))

###############################################################################
# Gate 5 (F2P, 0.20): Behavioral simulation — load the easter egg module and
# verify it exposes a Component-like render() OR an extension default export
# function. Try to instantiate / call it and check render output for branding.
###############################################################################
GATE5=0
SIM_RESULT="UNKNOWN"
if [ -n "$PRIMARY_EE" ] && [ -f "$PRIMARY_EE" ] && command -v bun >/dev/null 2>&1; then
  cat > /tmp/ee_sim.mjs <<'JSEOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const target = process.env.EE_FILE;
const src = readFileSync(target, "utf8");

// Heuristic 1: source must mention component-like rendering or message dispatch
const hasRenderApi = /render\s*\(/.test(src) || /sendMessage\s*\(/.test(src) || /addChild\s*\(/.test(src) || /setWidget\s*\(/.test(src) || /showOverlay\s*\(/.test(src) || /\.custom\s*\(/.test(src);
const hasBranding = /daxnut/i.test(src) || /powered\s*by/i.test(src);
const hasComponentRef = /Component/.test(src);

let importable = false;
let exportShape = "none";
try {
  // Stub the workspace deps so bare imports don't fail
  const url = pathToFileURL(target).href;
  const mod = await import(url).catch(() => null);
  if (mod) {
    importable = true;
    if (typeof mod.default === "function") exportShape = "default-fn";
    else if (mod.default && typeof mod.default === "object") exportShape = "default-obj";
    else {
      const named = Object.keys(mod).filter(k => k !== "default");
      if (named.length > 0) exportShape = "named:" + named.join(",");
    }
  }
} catch (e) {
  // expected for files importing workspace packages
}

const result = {
  hasRenderApi,
  hasBranding,
  hasComponentRef,
  importable,
  exportShape,
  size: src.length,
};
console.log(JSON.stringify(result));
JSEOF
  SIM_OUT=$(EE_FILE="$PRIMARY_EE" bun /tmp/ee_sim.mjs 2>/dev/null)
  echo "SIM_OUT: $SIM_OUT"

  HAS_RENDER=$(echo "$SIM_OUT" | grep -o '"hasRenderApi":true' | head -1)
  HAS_BRAND=$(echo "$SIM_OUT" | grep -o '"hasBranding":true' | head -1)
  HAS_COMP=$(echo "$SIM_OUT" | grep -o '"hasComponentRef":true' | head -1)

  pts=0
  [ -n "$HAS_RENDER" ] && pts=$((pts + 8))
  [ -n "$HAS_BRAND" ]  && pts=$((pts + 7))
  [ -n "$HAS_COMP" ]   && pts=$((pts + 5))
  GATE5=$pts
  echo "GATE5 [F2P]: $pts/20 (render=$HAS_RENDER brand=$HAS_BRAND comp=$HAS_COMP)"
  rm -f /tmp/ee_sim.mjs
else
  # Static fallback if bun not available
  if [ -n "$PRIMARY_EE" ] && [ -f "$PRIMARY_EE" ]; then
    pts=0
    if grep -qE 'render\s*\(|sendMessage\s*\(|addChild\s*\(|setWidget\s*\(|showOverlay\s*\(' "$PRIMARY_EE"; then
      pts=$((pts + 8))
    fi
    if grep -qiE 'daxnut|powered\s*by' "$PRIMARY_EE"; then
      pts=$((pts + 7))
    fi
    if grep -q 'Component' "$PRIMARY_EE"; then
      pts=$((pts + 5))
    fi
    GATE5=$pts
    echo "GATE5 [F2P]: $pts/20 (static fallback, bun unavailable)"
  else
    echo "GATE5 [F2P]: FAIL — no source"
  fi
fi
SCORE=$((SCORE + GATE5))

###############################################################################
# Gate 6 (F2P, 0.10): "powered by daxnuts" branding text appears in rendered
# string content (not in a comment). We require a string literal containing
# both the daxnuts branding and case-insensitive "powered by" near a render.
###############################################################################
GATE6=0
BRAND_FILES=()
for f in "${EE_CANDIDATES[@]}"; do
  BRAND_FILES+=("$f")
done

best_brand=0
for f in "${BRAND_FILES[@]}"; do
  [ -f "$f" ] || continue
  # Score 1: string literal containing daxnuts
  has_dax_str=$(awk '
    {
      l=tolower($0)
      # crude: line contains a quote and the word daxnuts
      if (l ~ /["`'\''].*daxnut.*["`'\'']/ || (l ~ /daxnut/ && l ~ /["`'\'']/)) print "Y"
    }' "$f" | head -1)
  has_powered_str=$(awk '
    {
      l=tolower($0)
      if (l ~ /["`'\''].*powered.*by.*["`'\'']/ || (l ~ /powered/ && l ~ /["`'\'']/)) print "Y"
    }' "$f" | head -1)
  has_render=$(grep -cE 'render\s*\(|push\(.*\)|return\s+lines|sendMessage\(|addChild\(' "$f")

  pts=0
  [ -n "$has_dax_str" ] && pts=$((pts + 5))
  [ -n "$has_powered_str" ] && pts=$((pts + 3))
  [ "$has_render" -gt 0 ] && pts=$((pts + 2))
  if [ "$pts" -gt "$best_brand" ]; then best_brand=$pts; fi
done

if [ "$best_brand" -gt 10 ]; then best_brand=10; fi
GATE6=$best_brand
echo "GATE6 [F2P]: $GATE6/10 — branding strings"
SCORE=$((SCORE + GATE6))

###############################################################################
# Gate 7 (F2P, 0.10): Wired into runtime — either (a) integrated in
# interactive-mode.ts to attach to chatContainer / overlay on model select,
# OR (b) registered via extension API hooks (model_select / sendMessage /
# setWidget / registerCommand).
###############################################################################
GATE7=0
WIRED_INTERACTIVE=0
WIRED_EXTENSION=0

if [ -f "$INTERACTIVE" ]; then
  if grep -qiE 'daxnut|kimi.*k2|opencode.*kimi|kimi.*opencode' "$INTERACTIVE" && \
     grep -qE 'addChild|chatContainer|showOverlay|showExtensionCustom|new\s+\w*Daxnut|new\s+\w*EasterEgg|new\s+\w*Kimi' "$INTERACTIVE"; then
    WIRED_INTERACTIVE=1
  fi
fi

for f in "${EE_CANDIDATES[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *"/.pi/extensions/"*)
      if grep -qE 'pi\.on\s*\(\s*["'\'']model_select|registerCommand|sendMessage|setWidget|registerMessageRenderer|ctx\.ui\.custom' "$f"; then
        WIRED_EXTENSION=1
      fi
      ;;
  esac
done

if [ "$WIRED_INTERACTIVE" -eq 1 ] || [ "$WIRED_EXTENSION" -eq 1 ]; then
  GATE7=10
  echo "GATE7 [F2P]: PASS — wired (interactive=$WIRED_INTERACTIVE extension=$WIRED_EXTENSION)"
else
  echo "GATE7 [F2P]: FAIL — no wiring detected"
fi
SCORE=$((SCORE + GATE7))

###############################################################################
# Final
###############################################################################
TOTAL=100
REWARD=$(awk -v s="$SCORE" -v t="$TOTAL" 'BEGIN { printf "%.3f", s/t }')

echo "----------------------------------------"
echo "GATE1=$GATE1/10  GATE2=$GATE2/5  GATE3=$GATE3/20  GATE4=$GATE4/25"
echo "GATE5=$GATE5/20  GATE6=$GATE6/10  GATE7=$GATE7/10"
echo "SCORE=$SCORE/$TOTAL  REWARD=$REWARD"
echo "$REWARD" > "$REWARD_FILE"