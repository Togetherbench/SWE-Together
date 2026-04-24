#!/bin/bash
# Verifier for pi-mono slash command fix task
# Bug: slash command autocomplete triggers on "/" at start of any newline,
# even when other lines have content. Should only trigger when editor is empty.
# Nop score: 0.10 (only P2P compilation gate passes on unmodified code)
set +e

EDITOR_FILE="/workspace/pi-mono/packages/tui/src/components/editor.ts"
CHANGELOG_FILE="/workspace/pi-mono/packages/tui/CHANGELOG.md"
REWARD_FILE="/logs/verifier/reward.txt"

mkdir -p /logs/verifier

REWARD=0

add_reward() {
    local weight="$1"
    local name="$2"
    REWARD=$(python3 -c "print(round($REWARD + $weight, 2))")
    echo "PASS [$weight]: $name"
}

echo "=== Slash Command Fix Verifier ==="
echo ""

cd /workspace/pi-mono

# ---------------------------------------------------------------
# Test 1 (P2P, 0.10): TypeScript compilation gate
# The project must continue to compile after changes.
# Uses tsgo as specified in the task instruction.
# ---------------------------------------------------------------
if npx tsgo --noEmit 2>&1; then
    add_reward 0.10 "TypeScript compiles (tsgo --noEmit)"
else
    echo "FAIL [0.10]: TypeScript compiles (tsgo --noEmit)"
fi

# ---------------------------------------------------------------
# Test 2 (F2P, 0.40): Behavioral slash gating test
# Extracts the isAtStartOfMessage method (or equivalent gating method)
# from the source, executes it with mock editor state via node, and
# verifies correct behavior:
#   - Empty editor -> slash allowed (true)
#   - Content on other lines -> slash blocked (false)
#   - All empty lines -> slash allowed (true)
# ---------------------------------------------------------------

cat > /tmp/test_slash_behavioral.js << 'JSEOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");

// Try to find a method body by name
function findMethodBody(name) {
    const re = new RegExp(
        "(?:private\\s+)?" + name + "\\([^)]*\\)\\s*(?::\\s*\\w+)?\\s*\\{([\\s\\S]*?)\\n\\t\\}"
    );
    const m = src.match(re);
    return m ? m[1] : null;
}

// Strategy 1: Look for isAtStartOfMessage
let methodBody = findMethodBody("isAtStartOfMessage");
let methodSource = "isAtStartOfMessage";

// Strategy 2: If not found, look for any private method that checks
// line emptiness (iterates lines and checks trim)
if (!methodBody) {
    const allMethods = [
        ...src.matchAll(
            /(?:private\s+)(\w+)\([^)]*\)\s*(?::\s*\w+)?\s*\{([\s\S]*?)\n\t\}/g
        ),
    ];
    for (const [, name, body] of allMethods) {
        if (
            body.includes("lines") &&
            body.includes("trim") &&
            (body.includes("every") ||
                body.includes("for") ||
                body.includes("some") ||
                body.includes("filter") ||
                body.includes("forEach"))
        ) {
            methodBody = body;
            methodSource = name;
            break;
        }
    }
}

if (!methodBody) {
    console.log(
        "FAIL: No gating method found (isAtStartOfMessage or equivalent)"
    );
    process.exit(1);
}

console.log("Testing method: " + methodSource);

// Prepare method body: inline helper calls, replace this.state
function prepareBody(body) {
    let prepared = body;

    // Find this.methodName() calls and try to inline their bodies
    const helperCalls = [
        ...new Set((body.match(/this\.([a-zA-Z]\w*)\(\)/g) || [])),
    ];
    for (const call of helperCalls) {
        const name = call.match(/this\.(\w+)\(/)[1];
        if (name === "state") continue;

        if (name === "getText") {
            prepared = prepared.replace(
                new RegExp("this\\." + name + "\\(\\)", "g"),
                'state.lines.join("\\n")'
            );
            continue;
        }

        const helperBody = findMethodBody(name);
        if (helperBody) {
            const inlined = helperBody.replace(/this\.state/g, "state");
            prepared = prepared.replace(
                new RegExp("this\\." + name + "\\(\\)", "g"),
                "(function(state){" + inlined + "})(state)"
            );
        }
    }

    prepared = prepared.replace(/this\.state/g, "state");
    return prepared;
}

function testMethod(lines, cursorLine, cursorCol) {
    const state = { lines: lines, cursorLine: cursorLine, cursorCol: cursorCol };
    const prepared = prepareBody(methodBody);
    try {
        const fn = new Function("state", prepared);
        return fn(state);
    } catch (e) {
        console.log("Execution error: " + e.message);
        return null;
    }
}

let failures = 0;

// Test A: Empty single-line editor, cursor at 0 -> true (slash allowed)
const tA = testMethod([""], 0, 0);
if (tA !== true) {
    console.log("FAIL testA: empty editor -> expected true, got " + tA);
    failures++;
} else {
    console.log("PASS testA: empty editor allows slash");
}

// Test B: Content on line 0, cursor on empty line 1 -> false (slash blocked)
const tB = testMethod(["hello world", ""], 1, 0);
if (tB !== false) {
    console.log("FAIL testB: content on other line -> expected false, got " + tB);
    failures++;
} else {
    console.log("PASS testB: content on other line blocks slash");
}

// Test C: All lines empty -> true (slash allowed)
const tC = testMethod(["", ""], 1, 0);
if (tC !== true) {
    console.log("FAIL testC: all empty lines -> expected true, got " + tC);
    failures++;
} else {
    console.log("PASS testC: all empty lines allows slash");
}

// Test D: Content on later line, cursor on first empty line -> false
const tD = testMethod(["", "content here"], 0, 0);
if (tD !== false) {
    console.log("FAIL testD: content on later line -> expected false, got " + tD);
    failures++;
} else {
    console.log("PASS testD: content on later line blocks slash");
}

if (failures > 0) {
    console.log(failures + " behavioral test(s) failed");
    process.exit(1);
}
console.log("All behavioral tests passed");
process.exit(0);
JSEOF

if node /tmp/test_slash_behavioral.js "$EDITOR_FILE" 2>&1; then
    add_reward 0.40 "behavioral: slash gating logic"
else
    echo "FAIL [0.40]: behavioral: slash gating logic"
fi

# ---------------------------------------------------------------
# Shared: extract diff for structural tests
# ---------------------------------------------------------------
diff_content=$(git diff -- packages/tui/src/components/editor.ts 2>/dev/null)
diff_lines=$(echo "$diff_content" | wc -l)

# ---------------------------------------------------------------
# Test 3 (F2P, 0.20): Slash command gating mechanism was fixed
# The fix must modify the code path that decides when slash
# commands trigger. Accepts ANY approach: modifying
# isAtStartOfMessage, adding a new gating method, reducing
# bare trimStart().startsWith("/") patterns, etc.
# ---------------------------------------------------------------
call_sites_ok=0

if [ "$diff_lines" -gt 5 ]; then
    # Approach A: isAtStartOfMessage method body was modified
    if echo "$diff_content" | grep -qP '^\-\s*.*return beforeCursor\.trim'; then
        call_sites_ok=1
    fi

    # Approach B: new multi-line or whole-editor checking logic added
    if echo "$diff_content" | grep -qP '^\+.*(lines.*join|getText\(\)|allText|every.*trim|some.*trim|isEmpty)'; then
        call_sites_ok=1
    fi

    # Approach C: a new gating method was added
    new_method=$(echo "$diff_content" | grep -oP '^\+\s*private\s+(\w+)\s*\(' | head -1 | grep -oP '\w+(?=\s*\()' || true)
    if [ -n "$new_method" ]; then
        call_sites_ok=1
    fi

    # Approach D: bare trimStart().startsWith("/") patterns reduced
    bare_slash=$(grep -cP 'trimStart\(\)\.startsWith\(\s*"/"\s*\)' "$EDITOR_FILE" 2>/dev/null || echo "0")
    bare_slash=$(echo "$bare_slash" | tr -d '[:space:]')
    if [ "${bare_slash:-0}" -le 2 ]; then
        call_sites_ok=1
    fi
fi

if [ "$call_sites_ok" -eq 1 ]; then
    add_reward 0.20 "slash gating mechanism fixed"
else
    echo "FAIL [0.20]: slash gating mechanism fixed"
fi

# ---------------------------------------------------------------
# Test 4 (F2P, 0.15): Changelog entry under [Unreleased]
# Must reference #904 or the slash command fix.
# ---------------------------------------------------------------
changelog_ok=0
if [ -f "$CHANGELOG_FILE" ]; then
    unreleased=$(sed -n '/## \[Unreleased\]/,/## \[/p' "$CHANGELOG_FILE" 2>/dev/null | head -30)
    if echo "$unreleased" | grep -qiP '(slash|#904|command\s+(menu|auto))'; then
        changelog_ok=1
    fi
fi
if [ "$changelog_ok" -eq 1 ]; then
    add_reward 0.15 "changelog entry for #904/slash fix"
else
    echo "FAIL [0.15]: changelog entry for #904/slash fix"
fi

# ---------------------------------------------------------------
# Test 5 (F2P, 0.10): New code checks for emptiness
# The diff must introduce code that checks whether editor content
# is empty (comparison to "" or checking trim/length).
# ---------------------------------------------------------------
logic_ok=0
if echo "$diff_content" | grep -qP '^\+.*===?\s*""' || \
   echo "$diff_content" | grep -qP '^\+.*\.trim\(\)\s*(!==?|===?)\s*""' || \
   echo "$diff_content" | grep -qP '^\+.*\.trim\(\)\.length\s*[>!=]' || \
   echo "$diff_content" | grep -qP '^\+.*\.length\s*===?\s*0'; then
    logic_ok=1
fi
if [ "$logic_ok" -eq 1 ]; then
    add_reward 0.10 "new code checks for emptiness"
else
    echo "FAIL [0.10]: new code checks for emptiness"
fi

# ---------------------------------------------------------------
# Test 6 (F2P, 0.05): editor.ts was modified (basic sanity)
# ---------------------------------------------------------------
if [ "$diff_lines" -gt 5 ]; then
    add_reward 0.05 "editor.ts modified"
else
    echo "FAIL [0.05]: editor.ts modified"
fi

# ---------------------------------------------------------------
# Final score
# ---------------------------------------------------------------
echo ""
echo "Total reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
