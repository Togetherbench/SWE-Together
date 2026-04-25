#!/bin/bash
set +e

EDITOR_FILE="/workspace/pi-mono/packages/tui/src/components/editor.ts"
CHANGELOG_FILE="/workspace/pi-mono/packages/tui/CHANGELOG.md"
REWARD_FILE="/logs/verifier/reward.txt"

mkdir -p /logs/verifier
mkdir -p /tmp/verifier

REWARD=0

add_reward() {
    local weight="$1"
    local name="$2"
    REWARD=$(awk -v r="$REWARD" -v w="$weight" 'BEGIN { printf "%.2f", r + w }')
    echo "PASS [$weight]: $name"
}

fail_reward() {
    local weight="$1"
    local name="$2"
    echo "FAIL [$weight]: $name"
}

echo "=== Slash Command Fix Verifier ==="
cd /workspace/pi-mono || { echo "$REWARD" > "$REWARD_FILE"; exit 0; }

# ------------------------------------------------------------------
# Test 1 (P2P, 0.10): TypeScript compilation gate
# ------------------------------------------------------------------
if npx tsgo --noEmit > /tmp/verifier/tsgo.log 2>&1; then
    add_reward 0.10 "TypeScript compiles (tsgo --noEmit)"
else
    fail_reward 0.10 "TypeScript compiles (tsgo --noEmit)"
    tail -40 /tmp/verifier/tsgo.log
fi

# ------------------------------------------------------------------
# Build a behavioral harness: extract relevant private methods from
# editor.ts, mock `this.state`, and exercise the gating logic with
# realistic editor states. We rely on the public-ish private methods
# `isAtStartOfMessage`, `isInSlashCommandContext`, and any helpers
# they call (`isSlashMenuAllowed`, `getText`).
# ------------------------------------------------------------------

cat > /tmp/verifier/harness.js << 'JSEOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

// Locate the class body
const classMatch = src.match(/class\s+\w+[^{]*\{([\s\S]*)\n\}\s*$/);
if (!classMatch) {
    console.log("HARNESS_ERROR: cannot locate class body");
    process.exit(2);
}
const classBody = classMatch[1];

// Extract a method body by name. Method definitions are tab-indented; the closing
// brace for the method is at one tab indentation. Capture the whole `(... ) ... { body }`.
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

// Build a synthetic class. Each method becomes a JS function on `this`.
// Replace this.state with this.state (kept), this.<helper>() left intact -
// we'll define them all on the same object.
function rewrite(body) {
    // No-op: keep this.* references; we'll define them all on a plain object.
    return body;
}

let synthFns = "";
for (const [name, m] of Object.entries(methods)) {
    const params = m.params || "";
    const body = rewrite(m.body);
    synthFns += `obj.${name} = function(${params}) {\n${body}\n};\n`;
}

// Build a stub for getText if not present (some implementations keep using lines directly)
if (!methods.getText) {
    synthFns += `obj.getText = function() { return this.state.lines.join("\\n"); };\n`;
}
// Build a stub for isSlashMenuAllowed if not present
if (!methods.isSlashMenuAllowed) {
    synthFns += `obj.isSlashMenuAllowed = function() { return this.state.cursorLine === 0; };\n`;
}

function evaluateState(state, action) {
    const obj = { state };
    let runner;
    try {
        runner = new Function(
            "obj",
            synthFns + "\nreturn obj;"
        );
    } catch (e) {
        console.log("HARNESS_COMPILE_ERROR:", e.message);
        return { error: "compile" };
    }
    let inst;
    try {
        inst = runner(obj);
    } catch (e) {
        console.log("HARNESS_INIT_ERROR:", e.message);
        return { error: "init" };
    }
    try {
        if (action === "isAtStartOfMessage") {
            return { value: !!inst.isAtStartOfMessage() };
        }
        if (action === "isInSlashCommandContext") {
            const cur = inst.state.lines[inst.state.cursorLine] || "";
            const before = cur.slice(0, inst.state.cursorCol);
            return { value: !!inst.isInSlashCommandContext(before) };
        }
    } catch (e) {
        return { error: e.message };
    }
}

// Compute "effective slash trigger": agent fixes might be in either
// isAtStartOfMessage, isInSlashCommandContext, or isSlashMenuAllowed.
// We treat the slash menu as triggered iff BOTH report-positive paths
// agree it should be: i.e. simulate what the editor does when "/" is at
// cursor. We compute a combined predicate.
function shouldTriggerSlash(state) {
    // Pretend user just typed "/" -> cursor sits after "/" on current line
    // Most relevant gate is isAtStartOfMessage OR isInSlashCommandContext when
    // text-before-cursor starts with "/"
    const r1 = evaluateState(state, "isAtStartOfMessage");
    const r2 = evaluateState(state, "isInSlashCommandContext");
    // if either errors, we still want a defined boolean — fall back on the
    // other; if both error, return null
    let v1 = r1 && typeof r1.value === "boolean" ? r1.value : null;
    let v2 = r2 && typeof r2.value === "boolean" ? r2.value : null;
    if (v1 === null && v2 === null) return null;
    // The buggy code triggers when EITHER says yes; the fixed code requires
    // the editor to be otherwise empty. We use AND of available signals,
    // but since either gate alone is sufficient to stop the bug, we use
    // OR of the relevant positive-check signals: this matches the editor's
    // actual code path which gates on isInSlashCommandContext / isAtStartOfMessage.
    // To be conservative we require BOTH to allow it (when both are defined),
    // because the real editor invokes the most restrictive gate.
    if (v1 !== null && v2 !== null) return v1 && v2;
    return v1 !== null ? v1 : v2;
}

const cases = [
    {
        name: "empty editor (single empty line, slash typed)",
        state: { lines: ["/"], cursorLine: 0, cursorCol: 1 },
        expect: true,
    },
    {
        name: "slash on empty line, content above",
        state: { lines: ["hello world", "/"], cursorLine: 1, cursorCol: 1 },
        expect: false,
    },
    {
        name: "slash on empty line, content below",
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
        name: "slash on line 2, line 1 has content",
        state: { lines: ["prior text", "", "/"], cursorLine: 2, cursorCol: 1 },
        expect: false,
    },
];

let pass = 0;
let total = 0;
for (const c of cases) {
    total++;
    const got = shouldTriggerSlash(c.state);
    if (got === null) {
        console.log(`SKIP: ${c.name} (no evaluable method)`);
        continue;
    }
    if (got === c.expect) {
        console.log(`PASS: ${c.name} -> ${got}`);
        pass++;
    } else {
        console.log(`FAIL: ${c.name} -> got ${got}, expected ${c.expect}`);
    }
}

console.log(`SUMMARY ${pass}/${total}`);
process.exit(0);
JSEOF

node /tmp/verifier/harness.js "$EDITOR_FILE" > /tmp/verifier/harness.out 2>&1
cat /tmp/verifier/harness.out

PASS_COUNT=$(grep -c '^PASS: ' /tmp/verifier/harness.out 2>/dev/null)
FAIL_COUNT=$(grep -c '^FAIL: ' /tmp/verifier/harness.out 2>/dev/null)
PASS_COUNT=${PASS_COUNT:-0}
FAIL_COUNT=${FAIL_COUNT:-0}

# ------------------------------------------------------------------
# Test 2 (F2P, 0.30): Critical bug-specific cases must pass:
#   - slash on empty line with content above -> false
#   - slash on empty line with content below -> false
#   - slash on line 2 with line 1 content -> false
# These are the exact regressions described in issue #904.
# ------------------------------------------------------------------
crit_pass=0
grep -q '^PASS: slash on empty line, content above' /tmp/verifier/harness.out && crit_pass=$((crit_pass+1))
grep -q '^PASS: slash on empty line, content below' /tmp/verifier/harness.out && crit_pass=$((crit_pass+1))
grep -q '^PASS: slash on line 2, line 1 has content' /tmp/verifier/harness.out && crit_pass=$((crit_pass+1))

if [ "$crit_pass" -eq 3 ]; then
    add_reward 0.30 "behavioral: bug-fix regressions (3/3 critical cases blocked)"
elif [ "$crit_pass" -eq 2 ]; then
    add_reward 0.20 "behavioral: bug-fix regressions (2/3 critical cases blocked)"
elif [ "$crit_pass" -eq 1 ]; then
    add_reward 0.10 "behavioral: bug-fix regressions (1/3 critical cases blocked)"
else
    fail_reward 0.30 "behavioral: bug-fix regressions (0/3 critical cases blocked)"
fi

# ------------------------------------------------------------------
# Test 3 (F2P, 0.20): Preserve legitimate slash-trigger cases:
#   - empty editor: slash works
#   - first line slash with all other lines blank: works
#   - slash mid-content: still doesn't trigger (was already correct)
# This guards against over-fixing (just disabling the menu entirely).
# ------------------------------------------------------------------
preserve_pass=0
grep -q '^PASS: empty editor' /tmp/verifier/harness.out && preserve_pass=$((preserve_pass+1))
grep -q '^PASS: slash on first line, all other lines blank' /tmp/verifier/harness.out && preserve_pass=$((preserve_pass+1))
grep -q '^PASS: slash typed mid-content' /tmp/verifier/harness.out && preserve_pass=$((preserve_pass+1))

if [ "$preserve_pass" -eq 3 ]; then
    add_reward 0.20 "behavioral: preserved legitimate cases (3/3)"
elif [ "$preserve_pass" -eq 2 ]; then
    add_reward 0.13 "behavioral: preserved legitimate cases (2/3)"
elif [ "$preserve_pass" -eq 1 ]; then
    add_reward 0.07 "behavioral: preserved legitimate cases (1/3)"
else
    fail_reward 0.20 "behavioral: preserved legitimate cases"
fi

# ------------------------------------------------------------------
# Test 4 (F2P, 0.15): Holistic harness pass rate (rewards solutions
# that pass all 6 cases, partial credit for at least 4).
# ------------------------------------------------------------------
if [ "$PASS_COUNT" -ge 6 ]; then
    add_reward 0.15 "holistic: all 6 behavioral cases pass"
elif [ "$PASS_COUNT" -ge 5 ]; then
    add_reward 0.10 "holistic: 5/6 behavioral cases pass"
elif [ "$PASS_COUNT" -ge 4 ]; then
    add_reward 0.05 "holistic: 4/6 behavioral cases pass"
else
    fail_reward 0.15 "holistic: behavioral pass count = $PASS_COUNT"
fi

# ------------------------------------------------------------------
# Test 5 (Structural, 0.10): The fix actually modifies a gating
# code path in editor.ts (not just adds dead code or only edits
# the changelog).
# ------------------------------------------------------------------
diff_content=$(git diff -- packages/tui/src/components/editor.ts 2>/dev/null)
diff_lines=$(echo "$diff_content" | grep -c '^[+-]')
diff_lines=${diff_lines:-0}

structural_ok=0
if [ "$diff_lines" -ge 4 ]; then
    # The diff should reference at least one of: lines, getText, every,
    # some, slice, or length, indicating multi-line awareness.
    if echo "$diff_content" | grep -E '^\+' | grep -qE '(lines\.(slice|every|some|length|join)|getText\(\)|\.length\s*===\s*1|\.length\s*<=\s*1)'; then
        structural_ok=1
    fi
fi

if [ "$structural_ok" -eq 1 ]; then
    add_reward 0.10 "structural: multi-line awareness added to gating logic"
else
    fail_reward 0.10 "structural: multi-line awareness in gating logic"
fi

# ------------------------------------------------------------------
# Test 6 (Structural, 0.10): Changelog entry under [Unreleased]
# with ### Fixed section referencing #904.
# ------------------------------------------------------------------
changelog_ok=0
if [ -f "$CHANGELOG_FILE" ]; then
    # Extract content between ## [Unreleased] and the next ## heading
    unreleased_block=$(awk '
        /^## \[Unreleased\]/ { capture=1; next }
        /^## \[/ && capture { exit }
        capture { print }
    ' "$CHANGELOG_FILE")

    if echo "$unreleased_block" | grep -qE '^### Fixed' && \
       echo "$unreleased_block" | grep -q '904'; then
        changelog_ok=1
    fi
fi

if [ "$changelog_ok" -eq 1 ]; then
    add_reward 0.10 "changelog: [Unreleased] ### Fixed entry references #904"
else
    fail_reward 0.10 "changelog: [Unreleased] ### Fixed entry references #904"
fi

# ------------------------------------------------------------------
# Test 7 (Sanity, 0.05): No accidental edits to the buggy bare
# pattern outside the gating method (file still uses `/` references
# in a sensible way; we just check the file is well-formed and not
# truncated).
# ------------------------------------------------------------------
file_ok=0
if [ -f "$EDITOR_FILE" ]; then
    line_count=$(wc -l < "$EDITOR_FILE")
    if [ "$line_count" -ge 100 ] && grep -q 'isAtStartOfMessage\|isInSlashCommandContext\|isSlashMenuAllowed' "$EDITOR_FILE"; then
        file_ok=1
    fi
fi

if [ "$file_ok" -eq 1 ]; then
    add_reward 0.05 "sanity: editor.ts intact and contains gating method"
else
    fail_reward 0.05 "sanity: editor.ts intact and contains gating method"
fi

echo ""
echo "=== Final reward: $REWARD ==="
echo "$REWARD" > "$REWARD_FILE"