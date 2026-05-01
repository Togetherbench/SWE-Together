#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

EDITOR_FILE="/workspace/pi-mono/packages/tui/src/components/editor.ts"
CHANGELOG_FILE="/workspace/pi-mono/packages/tui/CHANGELOG.md"
REWARD_FILE="/logs/verifier/reward.txt"

mkdir -p /logs/verifier
mkdir -p /tmp/verifier

REWARD=0

finish() {
    awk -v r="$REWARD" 'BEGIN { printf "%.2f\n", r }' > "$REWARD_FILE"
    cat "$REWARD_FILE"
    exit 0
}

add_reward() {
    local weight="$1"
    local name="$2"
    REWARD=$(awk -v r="$REWARD" -v w="$weight" 'BEGIN { printf "%.4f", r + w }')
    echo "PASS [$weight]: $name"
}

fail_reward() {
    local weight="$1"
    local name="$2"
    echo "FAIL [$weight]: $name"
}

echo "=== Slash Command Fix Verifier ==="
cd /workspace/pi-mono || finish

if [ ! -f "$EDITOR_FILE" ]; then
    echo "GATE FAIL: editor.ts missing"
    finish
fi

if ! command -v node >/dev/null 2>&1; then
    echo "GATE FAIL: node not on PATH"
    finish
fi

# ---------------------------------------------------------------
# P2P GATE: TypeScript compilation must succeed (no reward weight).
# ---------------------------------------------------------------
if ! npx tsgo --noEmit > /tmp/verifier/tsgo.log 2>&1; then
    echo "GATE FAIL: tsgo --noEmit failed (regression)"
    tail -40 /tmp/verifier/tsgo.log
    REWARD=0
    finish
fi
echo "GATE OK: tsgo --noEmit passes"

# ---------------------------------------------------------------
# Build behavioral harness for editor gating logic.
# Strategy: extract relevant methods (isAtStartOfMessage,
# isSlashMenuAllowed, isInSlashCommandContext, getText) from the
# class body and call them with synthesized state. Combine the two
# gating booleans (start-of-message AND in-slash-context) the same
# way the editor's keypress handler does.
# ---------------------------------------------------------------
cat > /tmp/verifier/harness.js << 'JSEOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

const classMatch = src.match(/class\s+\w+[^{]*\{([\s\S]*)\n\}\s*$/);
if (!classMatch) {
    console.log("HARNESS_ERROR: cannot locate class body");
    process.exit(2);
}
const classBody = classMatch[1];

function extractMethod(name) {
    const re = new RegExp(
        "(?:^|\\n)\\t(?:private\\s+|public\\s+|protected\\s+)?(?:async\\s+)?" +
            name +
            "\\s*\\(([^)]*)\\)\\s*(?::\\s*[^\\{]+?)?\\s*\\{([\\s\\S]*?)\\n\\t\\}"
    );
    const m = classBody.match(re);
    if (!m) return null;
    return { params: m[1].trim(), body: m[2] };
}

const wanted = [
    "isAtStartOfMessage",
    "isSlashMenuAllowed",
    "isInSlashCommandContext",
    "getText",
];

const methods = {};
for (const n of wanted) {
    const m = extractMethod(n);
    if (m) methods[n] = m;
}

let synthFns = "";
for (const [name, m] of Object.entries(methods)) {
    const params = m.params || "";
    synthFns += `obj.${name} = function(${params}) {\n${m.body}\n};\n`;
}
if (!methods.getText) {
    synthFns += `obj.getText = function() { return this.state.lines.join("\\n"); };\n`;
}
if (!methods.isSlashMenuAllowed) {
    // Fallback to base buggy behavior if method missing
    synthFns += `obj.isSlashMenuAllowed = function() { return this.state.cursorLine === 0; };\n`;
}

function evaluateState(state, action) {
    const obj = { state };
    let runner;
    try {
        runner = new Function("obj", synthFns + "\nreturn obj;");
    } catch (e) {
        return { error: "compile:" + e.message };
    }
    let inst;
    try { inst = runner(obj); } catch (e) { return { error: "init:" + e.message }; }
    try {
        if (action === "isAtStartOfMessage") return { value: !!inst.isAtStartOfMessage() };
        if (action === "isInSlashCommandContext") {
            const cur = inst.state.lines[inst.state.cursorLine] || "";
            const before = cur.slice(0, inst.state.cursorCol);
            return { value: !!inst.isInSlashCommandContext(before) };
        }
        if (action === "isSlashMenuAllowed") return { value: !!inst.isSlashMenuAllowed() };
    } catch (e) { return { error: e.message }; }
}

// The slash menu actually opens iff (isAtStartOfMessage OR
// isInSlashCommandContext) — as in the editor's keypress handler;
// many fixes restrict via either path. We require BOTH available
// signals to agree the menu is suppressed in bug cases. So:
//   menu_opens := isAtStartOfMessage OR isInSlashCommandContext
function shouldTriggerSlash(state) {
    const r1 = evaluateState(state, "isAtStartOfMessage");
    const r2 = evaluateState(state, "isInSlashCommandContext");
    let v1 = r1 && typeof r1.value === "boolean" ? r1.value : null;
    let v2 = r2 && typeof r2.value === "boolean" ? r2.value : null;
    if (v1 === null && v2 === null) return null;
    if (v1 === null) v1 = false;
    if (v2 === null) v2 = false;
    return v1 || v2;
}

// Cases. Each represents the editor state at the moment the user
// has just typed `/`. cursorLine/cursorCol describe cursor pos.
const cases = [
    {
        id: "empty_then_slash",
        name: "empty editor, single '/' typed",
        state: { lines: ["/"], cursorLine: 0, cursorCol: 1 },
        expect: true,
    },
    {
        id: "slash_on_newline_with_prior",
        name: "BUG: '/' on new line when prior line has content",
        state: { lines: ["hello world", "/"], cursorLine: 1, cursorCol: 1 },
        expect: false,
    },
    {
        id: "slash_first_line_content_below",
        name: "BUG: '/' on first line, content on line below",
        state: { lines: ["/", "tail content"], cursorLine: 0, cursorCol: 1 },
        expect: false,
    },
    {
        id: "slash_first_other_blank",
        name: "'/' first line, all other lines blank-empty",
        state: { lines: ["/", "", ""], cursorLine: 0, cursorCol: 1 },
        expect: true,
    },
    {
        id: "slash_mid_content",
        name: "'/' typed mid-text on line",
        state: { lines: ["abc/"], cursorLine: 0, cursorCol: 4 },
        expect: false,
    },
    {
        id: "slash_third_line_prior_text",
        name: "BUG: '/' on line 3 when line 1 has content",
        state: { lines: ["prior text", "", "/"], cursorLine: 2, cursorCol: 1 },
        expect: false,
    },
    {
        id: "slash_first_line_blank_continuation",
        name: "BUG: '/' first line, non-empty content several lines down",
        state: { lines: ["/", "", "more text"], cursorLine: 0, cursorCol: 1 },
        expect: false,
    },
];

const results = {};
for (const c of cases) {
    const got = shouldTriggerSlash(c.state);
    if (got === null) {
        console.log(`SKIP: ${c.id} (no evaluable method)`);
        results[c.id] = { ok: false, skipped: true, got: null, expected: c.expect };
        continue;
    }
    const ok = got === c.expect;
    console.log(`${ok ? "PASS" : "FAIL"}: ${c.id} -> got ${got}, expected ${c.expect} (${c.name})`);
    results[c.id] = { ok, got, expected: c.expect };
}

fs.writeFileSync("/tmp/verifier/results.json", JSON.stringify(results));
JSEOF

node /tmp/verifier/harness.js "$EDITOR_FILE" > /tmp/verifier/harness.out 2>&1
cat /tmp/verifier/harness.out

if [ ! -f /tmp/verifier/results.json ]; then
    echo "GATE FAIL: harness produced no results"
    finish
fi

case_ok() {
    node -e "
const r = require('/tmp/verifier/results.json');
process.exit(r['$1'] && r['$1'].ok ? 0 : 1);
"
}

# ---------------------------------------------------------------
# F2P GATES — distinct behavioral slices.
#
# On the buggy base:
#   - isSlashMenuAllowed() returns (cursorLine === 0)
#   - isAtStartOfMessage() returns true iff cursorLine===0 and
#     beforeCursor.trim()==='' or '/'
#   - isInSlashCommandContext() returns true iff cursorLine===0 and
#     beforeCursor starts with '/'
#
# So on the buggy base:
#   * empty_then_slash -> true (matches expect)            [non-discriminating]
#   * slash_on_newline_with_prior (cursor line 1) -> false (matches expect) [non-discriminating]
#   * slash_first_line_content_below (cursor line 0) -> true (BUG; expect false) ← FAILS on base
#   * slash_first_other_blank -> true (matches expect)     [non-discriminating]
#   * slash_mid_content (col 4 'abc/') -> isAtStart? before='abc/'.trim()='abc/' != '' or '/'; false. isInSlashContext? 'abc/'.startsWith('/')=false. -> false (matches expect) [non-discriminating]
#   * slash_third_line_prior_text (line 2) -> false (matches expect)        [non-discriminating]
#   * slash_first_line_blank_continuation (line 0, content several below) -> true (BUG; expect false) ← FAILS on base
#
# So discriminating cases on base buggy editor are:
#   slash_first_line_content_below, slash_first_line_blank_continuation
# A complete fix must additionally preserve the "non-discriminating"
# behaviors. Any patch that breaks them loses weight.
# ---------------------------------------------------------------

# Weight allocation (sum = 0.60, remaining 0.40 from upstream gates):
#   0.12  Discriminating bug case A: slash on line 0, content directly below
#   0.12  Discriminating bug case B: slash on line 0, content several lines below
#   0.06  Empty editor still triggers (regression guard for over-restriction)
#   0.06  '/' first line + only blank lines below still triggers
#   0.06  Mid-content '/' does NOT trigger (no over-trigger)
#   0.06  '/' on later line with empty prior should not trigger when prior has text
#   0.06  Changelog entry under [Unreleased] ### Fixed referencing #904
#   0.06  isSlashMenuAllowed body actually changed beyond cursorLine===0

# F2P 1 (0.12): primary bug — content on line below
if case_ok "slash_first_line_content_below"; then
    add_reward 0.12 "behavioral: slash on line 0 with content below does not trigger"
else
    fail_reward 0.12 "behavioral: slash on line 0 with content below does not trigger"
fi

# F2P 2 (0.12): bug — content several lines below
if case_ok "slash_first_line_blank_continuation"; then
    add_reward 0.12 "behavioral: slash on line 0 with later non-empty line does not trigger"
else
    fail_reward 0.12 "behavioral: slash on line 0 with later non-empty line does not trigger"
fi

# F2P 3 (0.06): regression — empty editor still triggers
if case_ok "empty_then_slash"; then
    add_reward 0.06 "regression: '/' on empty editor still triggers menu"
else
    fail_reward 0.06 "regression: '/' on empty editor still triggers menu"
fi

# F2P 4 (0.06): regression — only blank lines below still triggers
if case_ok "slash_first_other_blank"; then
    add_reward 0.06 "regression: '/' with only-blank lines below still triggers"
else
    fail_reward 0.06 "regression: '/' with only-blank lines below still triggers"
fi

# F2P 5 (0.06): regression — mid-content slash doesn't trigger
if case_ok "slash_mid_content"; then
    add_reward 0.06 "regression: mid-line '/' does not trigger menu"
else
    fail_reward 0.06 "regression: mid-line '/' does not trigger menu"
fi

# F2P 6 (0.06): regression — '/' on later line w/ prior text doesn't trigger
if case_ok "slash_on_newline_with_prior" && case_ok "slash_third_line_prior_text"; then
    add_reward 0.06 "regression: '/' on later line with prior text does not trigger"
else
    fail_reward 0.06 "regression: '/' on later line with prior text does not trigger"
fi

# F2P 7 (0.06): changelog entry properly added
CHLOG_OK=0
if [ -f "$CHANGELOG_FILE" ]; then
    # Need: under [Unreleased] there's a ### Fixed section referencing #904
    node -e '
const fs=require("fs");
const s=fs.readFileSync(process.argv[1],"utf8");
const m=s.match(/##\s*\[Unreleased\]([\s\S]*?)(?=\n##\s)/);
if(!m){process.exit(1);}
const body=m[1];
if(!/###\s*Fixed/i.test(body)){process.exit(2);}
if(!/#904/.test(body)){process.exit(3);}
process.exit(0);
' "$CHANGELOG_FILE"
    if [ $? -eq 0 ]; then CHLOG_OK=1; fi
fi
if [ "$CHLOG_OK" = "1" ]; then
    add_reward 0.06 "changelog: [Unreleased] ### Fixed entry referencing #904"
else
    fail_reward 0.06 "changelog: [Unreleased] ### Fixed entry referencing #904"
fi

# F2P 8 (0.06): isSlashMenuAllowed (or one of the gating fns) changed
# beyond the trivial buggy body. Detect that the editor source no longer
# contains ONLY `return this.state.cursorLine === 0;` as the body of
# isSlashMenuAllowed AND that at least one of the gating methods now
# checks for additional content (lines.length, lines.slice, every, etc.).
GATING_OK=0
node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8");
function extract(name){
  const re=new RegExp("(?:^|\\n)\\t(?:private\\s+|public\\s+|protected\\s+)?(?:async\\s+)?"+name+"\\s*\\([^)]*\\)\\s*(?::\\s*[^{]+?)?\\s*\\{([\\s\\S]*?)\\n\\t\\}");
  const m=src.match(re); return m?m[1]:null;
}
const allowed=extract("isSlashMenuAllowed")||"";
const atStart=extract("isAtStartOfMessage")||"";
const inCtx=extract("isInSlashCommandContext")||"";
const combined=allowed+"\n"+atStart+"\n"+inCtx;
// Reject if isSlashMenuAllowed body is unchanged from buggy base and
// neither of the other two methods adds an emptiness check.
const buggyAllowed=/^\s*return\s+this\.state\.cursorLine\s*===\s*0\s*;\s*$/m.test(allowed.trim()) && allowed.trim().split(/\n/).length<=2;
const hasEmptinessSignal=/lines\.length\s*===\s*1/.test(combined) || /lines\.slice\s*\(\s*1\s*\)/.test(combined) || /\.every\s*\(/.test(combined) || /lines\.some\s*\(/.test(combined) || /getText\s*\(\s*\)\s*\.\s*trim/.test(combined);
if(!hasEmptinessSignal){process.exit(1);}
process.exit(0);
' "$EDITOR_FILE"
if [ $? -eq 0 ]; then GATING_OK=1; fi
if [ "$GATING_OK" = "1" ]; then
    add_reward 0.06 "structure: gating logic checks editor emptiness (not just cursorLine)"
else
    fail_reward 0.06 "structure: gating logic checks editor emptiness (not just cursorLine)"
fi

echo "=== FINAL REWARD (pre-upstream) ==="
awk -v r="$REWARD" 'BEGIN { printf "%.4f\n", r }' > "$REWARD_FILE"
cat "$REWARD_FILE"

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"
: > "$GATES_FILE"

# F2P upstream gate 1: CHANGELOG [Unreleased] has ### Fixed entry for #904
echo "--- upstream gate: f2p_upstream_changelog_904 ---"
cd /workspace/pi-mono
node -e "const fs=require('fs'); const s=fs.readFileSync('packages/tui/CHANGELOG.md','utf8'); const m=s.match(/## \\[Unreleased\\]([\\s\\S]*?)(?=\\n## )/); if(!m) process.exit(1); if(!/### Fixed/.test(m[1])) process.exit(1); if(!/#904/.test(m[1])) process.exit(1);" 2>&1
if [ $? -eq 0 ]; then
    echo '{"id": "f2p_upstream_changelog_904", "passed": true, "detail": "CHANGELOG [Unreleased] has ### Fixed with #904"}' >> "$GATES_FILE"
    echo "PASS: f2p_upstream_changelog_904"
else
    echo '{"id": "f2p_upstream_changelog_904", "passed": false, "detail": "CHANGELOG [Unreleased] missing ### Fixed entry for #904"}' >> "$GATES_FILE"
    echo "FAIL: f2p_upstream_changelog_904"
fi

# F2P upstream gate 2: isAtStartOfMessage checks editor emptiness
echo "--- upstream gate: f2p_upstream_structural_emptiness ---"
node -e "const fs=require('fs'); const s=fs.readFileSync('packages/tui/src/components/editor.ts','utf8'); const m=s.match(/private isAtStartOfMessage\\(\\)[^{]*\\{[\\s\\S]*?\\n\\t\\}/); if(!m) process.exit(2); if(!(/lines\\.slice|otherLinesEmpty|\\.every\\(|lines\\.some|\\.getText\\(\\)\\.trim/.test(m[0]))) process.exit(1);" 2>&1
if [ $? -eq 0 ]; then
    echo '{"id": "f2p_upstream_structural_emptiness", "passed": true, "detail": "isAtStartOfMessage has editor emptiness check"}' >> "$GATES_FILE"
    echo "PASS: f2p_upstream_structural_emptiness"
else
    echo '{"id": "f2p_upstream_structural_emptiness", "passed": false, "detail": "isAtStartOfMessage missing editor emptiness check"}' >> "$GATES_FILE"
    echo "FAIL: f2p_upstream_structural_emptiness"
fi

# P2P upstream gate 1: tsgo compilation
echo "--- upstream gate: p2p_upstream_tsgo_tui ---"
npx tsgo -p packages/tui/tsconfig.build.json --noEmit > /tmp/verifier/tsgo_upstream.log 2>&1
if [ $? -eq 0 ]; then
    echo '{"id": "p2p_upstream_tsgo_tui", "passed": true, "detail": "tsgo compilation succeeded"}' >> "$GATES_FILE"
    echo "PASS: p2p_upstream_tsgo_tui"
else
    echo '{"id": "p2p_upstream_tsgo_tui", "passed": false, "detail": "tsgo compilation failed"}' >> "$GATES_FILE"
    echo "FAIL: p2p_upstream_tsgo_tui"
fi

# P2P upstream gate 2: editor tests
echo "--- upstream gate: p2p_upstream_editor_tests ---"
node --test --import tsx packages/tui/test/editor.test.ts > /tmp/verifier/editor_tests.log 2>&1
if [ $? -eq 0 ]; then
    echo '{"id": "p2p_upstream_editor_tests", "passed": true, "detail": "editor tests passed"}' >> "$GATES_FILE"
    echo "PASS: p2p_upstream_editor_tests"
else
    echo '{"id": "p2p_upstream_editor_tests", "passed": false, "detail": "editor tests failed"}' >> "$GATES_FILE"
    echo "FAIL: p2p_upstream_editor_tests"
fi
# ---- end ----

# ---- upstream reward adjustment ----
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_behavioral_content_below": 0.12,
    "f2p_behavioral_blank_continuation": 0.12,
    "f2p_regression_empty_editor": 0.06,
    "f2p_regression_blank_below": 0.06,
    "f2p_regression_mid_content": 0.06,
    "f2p_regression_later_line": 0.06,
    "f2p_changelog": 0.06,
    "f2p_structural_gating": 0.06,
    "f2p_upstream_changelog_904": 0.2,
    "f2p_upstream_structural_emptiness": 0.2
}
P2P_REGRESSION = ["p2p_upstream_tsgo_tui", "p2p_upstream_editor_tests"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

p2p_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Preserve the bash-computed legacy reward and add upstream F2P gate
    # weights on top for any upstream gate that passed.
    reward = existing
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
echo "=== FINAL REWARD (post-upstream) ==="
cat /logs/verifier/reward.txt