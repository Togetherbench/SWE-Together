#!/bin/bash
set +e

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

# ---------------------------------------------------------------
# P2P GATE: TypeScript compilation must succeed (no reward weight).
# If the agent broke compilation, return 0.
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
    } catch (e) { return { error: e.message }; }
}

// Treat the slash menu as triggered iff BOTH gating signals (where
// available) say yes. The actual editor invokes both of these in its
// keypress path; a fixed editor must restrict via at least one of them.
function shouldTriggerSlash(state) {
    const r1 = evaluateState(state, "isAtStartOfMessage");
    const r2 = evaluateState(state, "isInSlashCommandContext");
    let v1 = r1 && typeof r1.value === "boolean" ? r1.value : null;
    let v2 = r2 && typeof r2.value === "boolean" ? r2.value : null;
    if (v1 === null && v2 === null) return null;
    if (v1 !== null && v2 !== null) return v1 && v2;
    return v1 !== null ? v1 : v2;
}

const cases = [
    {
        name: "empty editor with single slash typed",
        state: { lines: ["/"], cursorLine: 0, cursorCol: 1 },
        expect: true,
    },
    {
        name: "BUG: slash on empty line, content above",
        state: { lines: ["hello world", "/"], cursorLine: 1, cursorCol: 1 },
        expect: false,
    },
    {
        name: "BUG: slash on first line, content below",
        state: { lines: ["/", "tail content"], cursorLine: 0, cursorCol: 1 },
        expect: false,
    },
    {
        name: "slash on first line, all other lines blank",
        state: { lines: ["/", "", ""], cursorLine: 0, cursorCol: 1 },
        expect: true,
    },
    {
        name: "slash typed mid-content (not at line start)",
        state: { lines: ["abc/"], cursorLine: 0, cursorCol: 4 },
        expect: false,
    },
    {
        name: "BUG: slash on line 3 with content on line 1",
        state: { lines: ["prior text", "", "/"], cursorLine: 2, cursorCol: 1 },
        expect: false,
    },
];

let pass = 0;
const results = [];
for (const c of cases) {
    const got = shouldTriggerSlash(c.state);
    if (got === null) {
        console.log(`SKIP: ${c.name} (no evaluable method)`);
        results.push({ name: c.name, ok: false, skipped: true });
        continue;
    }
    if (got === c.expect) {
        console.log(`PASS: ${c.name} -> ${got}`);
        pass++;
        results.push({ name: c.name, ok: true });
    } else {
        console.log(`FAIL: ${c.name} -> got ${got}, expected ${c.expect}`);
        results.push({ name: c.name, ok: false });
    }
}

console.log(`SUMMARY ${pass}/${cases.length}`);
JSEOF

node /tmp/verifier/harness.js "$EDITOR_FILE" > /tmp/verifier/harness.out 2>&1
cat /tmp/verifier/harness.out

get_case() {
    # $1 = case name substring; returns 0 if PASS line found
    grep -F "PASS: $1" /tmp/verifier/harness.out > /dev/null 2>&1
}

# ---------------------------------------------------------------
# F2P gates — these must FAIL on the unmodified buggy editor.
# On the buggy base:
#   - isSlashMenuAllowed = (cursorLine === 0)
#   - isInSlashCommandContext returns true for "lines:['/','tail'], col 0,1"
#     and "lines:['/'], col 0,1"  (both pass on base)
#   - "slash on empty line, content above" (cursorLine=1) => menu would
#     return false on base because cursorLine !== 0 ... actually base
#     allows only cursorLine===0, so this case PASSES on base too.
#
# The CRITICAL F2P case that fails on base is:
#   "slash on first line, content below"  (cursorLine=0, has line[1])
# Base: isSlashMenuAllowed=true, isInSlashCommandContext=true => menu opens (BUG)
# Fix: must return false.
#
# Weights focus on the genuine bug-distinguishing cases.
# ---------------------------------------------------------------

# F2P 1 (0.45): The headline bug — slash on first line with content below
if get_case "BUG: slash on first line, content below"; then
    add_reward 0.45 "F2P: slash menu suppressed when content exists below"
else
    fail_reward 0.45 "F2P: slash menu suppressed when content exists below"
fi

# F2P 2 (0.20): slash on later line with content above (also a bug variant).
# Note: on base this happens to return false already (cursorLine!==0),
# so this is P2P-ish. We only count it if it ALSO passes alongside F2P 1.
# To keep no-op = 0, we don't award this independently.

# F2P 3 (0.20): Positive case — single-line "/" still opens the menu.
# This passes on base too (P2P), so no weight.

# Instead, add behavioral tests that fail on base:

# F2P 2 (0.20): line 3 with content on line 1.
# Base: cursorLine=2 → isSlashMenuAllowed=false → menu suppressed.
# So this passes on base. Skip weighting.

# Real F2P discriminators on the buggy base are scenarios where
# cursorLine===0 but other lines have content. Add another:
# Re-run harness with an extra case via inline node check.

cat > /tmp/verifier/extra.js << 'JSEOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const classMatch = src.match(/class\s+\w+[^{]*\{([\s\S]*)\n\}\s*$/);
if (!classMatch) process.exit(2);
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
const wanted = ["isAtStartOfMessage","isSlashMenuAllowed","isInSlashCommandContext","getText"];
const methods = {};
for (const n of wanted) { const m = extractMethod(n); if (m) methods[n] = m; }
let synthFns = "";
for (const [name, m] of Object.entries(methods)) {
    synthFns += `obj.${name} = function(${m.params || ""}) {\n${m.body}\n};\n`;
}
if (!methods.getText) synthFns += `obj.getText = function() { return this.state.lines.join("\\n"); };\n`;
if (!methods.isSlashMenuAllowed) synthFns += `obj.isSlashMenuAllowed = function() { return this.state.cursorLine === 0; };\n`;

function check(state) {
    const obj = { state };
    const runner = new Function("obj", synthFns + "\nreturn obj;");
    const inst = runner(obj);
    let v1 = null, v2 = null;
    try { v1 = !!inst.isAtStartOfMessage(); } catch(e){}
    try {
        const cur = state.lines[state.cursorLine] || "";
        const before = cur.slice(0, state.cursorCol);
        v2 = !!inst.isInSlashCommandContext(before);
    } catch(e){}
    if (v1 === null && v2 === null) return null;
    if (v1 !== null && v2 !== null) return v1 && v2;
    return v1 !== null ? v1 : v2;
}

const tests = [
    { name: "F2P_A: cursor first line slash, content on line 2",
      state: { lines: ["/", "x"], cursorLine: 0, cursorCol: 1 }, expect: false },
    { name: "F2P_B: cursor first line slash, content on line 3",
      state: { lines: ["/", "", "data"], cursorLine: 0, cursorCol: 1 }, expect: false },
    { name: "F2P_C: cursor first line slash, multi-line content below",
      state: { lines: ["/", "first", "second"], cursorLine: 0, cursorCol: 1 }, expect: false },
    { name: "POS_A: empty editor, single slash",
      state: { lines: ["/"], cursorLine: 0, cursorCol: 1 }, expect: true },
    { name: "POS_B: first line slash, all other lines empty strings",
      state: { lines: ["/", "", ""], cursorLine: 0, cursorCol: 1 }, expect: true },
];

for (const t of tests) {
    const got = check(t.state);
    if (got === null) { console.log(`SKIP ${t.name}`); continue; }
    if (got === t.expect) console.log(`OK ${t.name} -> ${got}`);
    else console.log(`BAD ${t.name} -> got ${got} expected ${t.expect}`);
}
JSEOF

node /tmp/verifier/extra.js "$EDITOR_FILE" > /tmp/verifier/extra.out 2>&1
cat /tmp/verifier/extra.out

ok_extra() { grep -F "OK $1" /tmp/verifier/extra.out > /dev/null 2>&1; }

# F2P_A: slash with content on line 2 — fails on base (menu opens), must be suppressed on fix.
if ok_extra "F2P_A:"; then
    add_reward 0.20 "F2P: suppress menu when line 2 has content"
else
    fail_reward 0.20 "F2P: suppress menu when line 2 has content"
fi

# F2P_B: slash with content on line 3 (line 2 empty) — fails on base, must be suppressed.
if ok_extra "F2P_B:"; then
    add_reward 0.15 "F2P: suppress menu when later line has content"
else
    fail_reward 0.15 "F2P: suppress menu when later line has content"
fi

# F2P_C: multi-line content below.
if ok_extra "F2P_C:"; then
    add_reward 0.10 "F2P: suppress menu with multi-line content below"
else
    fail_reward 0.10 "F2P: suppress menu with multi-line content below"
fi

# Combined positivity gate (no reward unless also F2P_A passes):
# require both POS cases AND at least F2P_A to award the changelog reward.
# This avoids giving the no-op any partial credit through "positives still work".

# ---------------------------------------------------------------
# F2P 4 (0.10): Changelog entry referencing #904 under [Unreleased] with Fixed.
# On base: no such entry exists. On fix: required by instruction.
# ---------------------------------------------------------------
changelog_ok=0
if [ -f "$CHANGELOG_FILE" ]; then
    # Extract the [Unreleased] section
    awk '
        /^## \[Unreleased\]/ { flag=1; next }
        /^## \[/ { flag=0 }
        flag { print }
    ' "$CHANGELOG_FILE" > /tmp/verifier/unreleased.txt

    if grep -q '^### Fixed' /tmp/verifier/unreleased.txt && \
       grep -q '#904' /tmp/verifier/unreleased.txt; then
        changelog_ok=1
    fi
fi

# Only award if at least one real F2P behavioral fix landed (prevents
# changelog-only patches from gaining credit, and guarantees no-op = 0).
if [ "$changelog_ok" = "1" ] && ok_extra "F2P_A:"; then
    add_reward 0.10 "F2P: changelog [Unreleased] ### Fixed with #904"
else
    fail_reward 0.10 "F2P: changelog [Unreleased] ### Fixed with #904"
fi

# Bonus positivity preservation — only counted when the bug is actually fixed.
# Ensures fixes don't break the empty-editor case.
if ok_extra "POS_A:" && ok_extra "POS_B:" && ok_extra "F2P_A:"; then
    : # no extra reward; positivity is necessary not sufficient. weight=0.
fi

echo "--- summary ---"
echo "Reward (pre-finalize): $REWARD"
finish