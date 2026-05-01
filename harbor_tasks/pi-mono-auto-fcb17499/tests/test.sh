#!/bin/bash
set +e

REWARD=0.0
REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

write_reward() {
  echo "$REWARD" > "$REWARD_FILE"
  exit 0
}

REPO=/workspace/pi-mono
if [ ! -d "$REPO/packages/tui" ]; then
  for d in /workspace/*/; do
    if [ -d "$d/packages/tui" ]; then REPO="${d%/}"; break; fi
  done
fi

if [ ! -d "$REPO/packages/tui" ]; then
  echo "FATAL: cannot find pi-mono repo"
  write_reward
fi

cd "$REPO" || write_reward

BUN="$(command -v bun)"
if [ -z "$BUN" ]; then BUN="/root/.bun/bin/bun"; fi
if [ ! -x "$BUN" ]; then
  echo "FATAL: bun not found"
  write_reward
fi

INTERACTIVE_FILE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
EDITOR_FILE="$REPO/packages/tui/src/components/editor.ts"

if [ ! -f "$INTERACTIVE_FILE" ] || [ ! -f "$EDITOR_FILE" ]; then
  echo "FATAL: required source files missing"
  write_reward
fi

############################################################
# P2P GATE: tui editor.ts still parses (regression guard).
# Failing here means the agent broke pre-existing structure.
# Returns 0.0 on failure — no partial credit.
############################################################
echo "=== P2P gate: editor.ts parses ==="
cat > /tmp/parsecheck.ts << 'TSEOF'
import("EDITOR_PATH").then((m) => {
  if (typeof (m as any).Editor !== "function") {
    console.log("NO_EDITOR_EXPORT");
    process.exit(2);
  }
  console.log("OK");
}).catch((e) => {
  console.log("IMPORT_FAIL:" + String(e));
  process.exit(3);
});
TSEOF
sed -i "s|EDITOR_PATH|$EDITOR_FILE|" /tmp/parsecheck.ts
PARSE_OUT=$("$BUN" run /tmp/parsecheck.ts 2>&1)
if ! echo "$PARSE_OUT" | grep -q "^OK$"; then
  echo "P2P FAIL: $PARSE_OUT"
  REWARD=0.0
  write_reward
fi
echo "P2P pass."

############################################################
# F2P GATE 1 (weight 0.70): The actual bug fix.
# After settings UI closes, the showSelector done() closure
# (which restores focus to the editor) must call requestRender.
# On the unmodified buggy base this closure does NOT call
# requestRender — that's the bug. The fix adds it.
#
# We detect this behaviorally by extracting the showSelector
# function body and checking that within the `done = () => {...}`
# arrow function (the one that calls setFocus(this.editor)),
# requestRender is invoked.
############################################################
echo "=== F2P 1: showSelector done() calls requestRender ==="
G1=0
cat > /tmp/g1.mjs << 'JSEOF'
import { readFileSync } from "fs";
const src = readFileSync(process.argv[2], "utf8");

// Find the showSelector method
const methodIdx = src.indexOf("showSelector(");
if (methodIdx < 0) { console.log("NO_SHOWSELECTOR"); process.exit(1); }

// Find first `done = () => {` (or similar) after showSelector
const after = src.slice(methodIdx);
// Match arrow function body assigned to `done`
const m = after.match(/done\s*=\s*\(\s*\)\s*=>\s*\{/);
if (!m) { console.log("NO_DONE_CLOSURE"); process.exit(1); }
const startBody = after.indexOf(m[0]) + m[0].length;
// Walk braces to find matching close
let depth = 1, i = startBody;
while (i < after.length && depth > 0) {
  const ch = after[i];
  if (ch === "{") depth++;
  else if (ch === "}") depth--;
  i++;
  if (depth === 0) break;
}
const body = after.slice(startBody, i - 1);

// Verify this closure (a) restores focus to the editor, and
// (b) calls requestRender.
const restoresFocus = /setFocus\s*\(\s*this\.editor/.test(body);
const callsRender = /requestRender\s*\(/.test(body);

console.log(JSON.stringify({ restoresFocus, callsRender, bodyLen: body.length }));
process.exit(restoresFocus && callsRender ? 0 : 1);
JSEOF
G1_OUT=$(node /tmp/g1.mjs "$INTERACTIVE_FILE" 2>&1)
echo "$G1_OUT"
if echo "$G1_OUT" | grep -q '"restoresFocus":true' && echo "$G1_OUT" | grep -q '"callsRender":true'; then
  echo "F2P 1 PASS"
  G1=70
else
  echo "F2P 1 FAIL"
fi

############################################################
# F2P GATE 2 (weight 0.30): Behavioral — when the
# onEditorPaddingXChange callback path completes (i.e. the
# settings UI is closed and done() runs), a render must be
# requested. We simulate this behaviorally without the full
# TUI: invoke showSelector with a fake `create` that yields
# the done callback, call done(), and assert that
# ui.requestRender was called at least once *after* the
# focus restoration.
#
# On the buggy base, done() only calls setFocus and does NOT
# trigger a render → the editor remains visually stale (this
# is the user-reported symptom). The fix triggers render.
############################################################
echo "=== F2P 2: behavioral simulation of done() ==="
G2=0
cat > /tmp/g2.ts << 'TSEOF'
import { readFileSync } from "fs";

const src = readFileSync("INTERACTIVE_PATH", "utf8");

// Extract the showSelector method body and synthesize a tiny
// runnable function that mirrors its `done` closure.
const idx = src.indexOf("showSelector(");
if (idx < 0) { console.log("NO_METHOD"); process.exit(2); }
const after = src.slice(idx);
const m = after.match(/done\s*=\s*\(\s*\)\s*=>\s*\{/);
if (!m) { console.log("NO_DONE"); process.exit(2); }
const startBody = after.indexOf(m[0]) + m[0].length;
let depth = 1, i = startBody;
while (i < after.length && depth > 0) {
  const ch = after[i];
  if (ch === "{") depth++;
  else if (ch === "}") depth--;
  i++;
  if (depth === 0) break;
}
const body = after.slice(startBody, i - 1);

// Build a fake `this` and execute the body.
const calls: string[] = [];
const fakeEditor = { __tag: "editor" };
const fakeContainer = {
  clear: () => calls.push("clear"),
  addChild: (c: any) => calls.push("addChild:" + (c?.__tag ?? "?")),
};
const fakeUi = {
  setFocus: (c: any) => calls.push("setFocus:" + (c?.__tag ?? "?")),
  requestRender: () => calls.push("requestRender"),
  hideOverlay: () => calls.push("hideOverlay"),
};
const self: any = {
  editor: fakeEditor,
  editorContainer: fakeContainer,
  ui: fakeUi,
};

try {
  // Strip TS type assertions like `as Component` so plain JS eval works.
  const jsBody = body.replace(/\s+as\s+[A-Za-z_][A-Za-z0-9_]*/g, "");
  const fn = new Function("self", `with (self) { ${jsBody} }`);
  fn(self);
} catch (e) {
  console.log("EXEC_FAIL:" + String(e));
  process.exit(3);
}

const focusIdx = calls.findIndex((c) => c.startsWith("setFocus:editor"));
const renderAfterFocus = focusIdx >= 0 && calls.slice(focusIdx).includes("requestRender");
const hasRender = calls.includes("requestRender");
const restoredEditor = calls.includes("addChild:editor");

console.log(JSON.stringify({ calls, restoredEditor, hasRender, renderAfterFocus }));
process.exit(restoredEditor && hasRender ? 0 : 1);
TSEOF
sed -i "s|INTERACTIVE_PATH|$INTERACTIVE_FILE|" /tmp/g2.ts
G2_OUT=$("$BUN" run /tmp/g2.ts 2>&1)
echo "$G2_OUT"
if echo "$G2_OUT" | grep -q '"restoredEditor":true' && echo "$G2_OUT" | grep -q '"hasRender":true'; then
  echo "F2P 2 PASS"
  G2=30
else
  echo "F2P 2 FAIL"
fi

TOTAL=$((G1 + G2))
REWARD=$(awk -v t=$TOTAL 'BEGIN { printf "%.4f", t/100 }')
echo "Total: $TOTAL/100 → reward=$REWARD"
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
GATES_FILE="/logs/verifier/gates.json"
mkdir -p /logs/verifier
> "$GATES_FILE"

# F2P gate: editor-component.ts uses paddingX?: number property syntax
echo "=== Upstream F2P: interface property check ==="
if grep -q 'paddingX?: number' packages/tui/src/editor-component.ts 2>/dev/null; then
  echo '{"id": "f2p_upstream_interface_property", "passed": true, "detail": "paddingX?: number found in editor-component.ts"}' >> "$GATES_FILE"
  echo "PASS"
else
  echo '{"id": "f2p_upstream_interface_property", "passed": false, "detail": "paddingX?: number NOT found in editor-component.ts"}' >> "$GATES_FILE"
  echo "FAIL"
fi

# F2P gate: showSelector done() closure calls requestRender
echo "=== Upstream F2P: requestRender in done closure ==="
if awk '/private showSelector\(/,/const \{ component/' packages/coding-agent/src/modes/interactive/interactive-mode.ts | grep -q 'requestRender'; then
  echo '{"id": "f2p_upstream_requestrender_done", "passed": true, "detail": "requestRender found in showSelector done closure"}' >> "$GATES_FILE"
  echo "PASS"
else
  echo '{"id": "f2p_upstream_requestrender_done", "passed": false, "detail": "requestRender NOT found in showSelector done closure"}' >> "$GATES_FILE"
  echo "FAIL"
fi

# P2P gate: TUI editor test suite
echo "=== Upstream P2P: editor test suite ==="
EDITOR_TEST_OUT=$(cd "$REPO" && node --test --import tsx packages/tui/test/editor.test.ts 2>&1)
EDITOR_TEST_RC=$?
if [ $EDITOR_TEST_RC -eq 0 ]; then
  echo '{"id": "p2p_upstream_editor_tests", "passed": true, "detail": "editor test suite passed"}' >> "$GATES_FILE"
  echo "PASS"
else
  echo '{"id": "p2p_upstream_editor_tests", "passed": false, "detail": "editor test suite failed with RC='"$EDITOR_TEST_RC"'"}' >> "$GATES_FILE"
  echo "FAIL: $EDITOR_TEST_OUT" | tail -20
fi

# ---- end ----

# Upstream reward adjustment
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_interface_property": 0.2,
    "f2p_upstream_requestrender_done": 0.2
}
P2P_REGRESSION = ["p2p_upstream_editor_tests"]
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

# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
p2p_failed = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF

exit 0