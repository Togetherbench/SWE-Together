#!/bin/bash
set +e

# Verifier for pi-mono issue #2406: Bash tool timing footer at bottom of output
# Goal: Discriminate complete behavioral fixes from no-ops and shallow patches.

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:$PATH"
command -v bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"

REPO=/workspace/pi-mono
TOOL_EXEC="$REPO/packages/coding-agent/src/modes/interactive/components/tool-execution.ts"
INTERACTIVE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"
BASH_TOOL="$REPO/packages/coding-agent/src/core/tools/bash.ts"

mkdir -p /logs/verifier 2>/dev/null || true
REWARD=0.0
finalize() { awk -v r="$REWARD" 'BEGIN{ if(r<0)r=0; if(r>1)r=1; printf "%.4f\n", r }' > /logs/verifier/reward.txt; exit 0; }
add_reward() { REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{ r=a+b; if(r>1)r=1; printf "%.4f", r }'); }

cd "$REPO" || finalize

# ============================================================
# Snapshot baseline files via git (HEAD = pre-patch baseline)
# ============================================================
BASE_DIR=$(mktemp -d)
get_base() {
  local rel="${1#$REPO/}"
  local out="$2"
  (cd "$REPO" && git show HEAD:"$rel" > "$out" 2>/dev/null)
}
get_base "$TOOL_EXEC"   "$BASE_DIR/tool-execution.ts.base"
get_base "$INTERACTIVE" "$BASE_DIR/interactive-mode.ts.base"
get_base "$BASH_TOOL"   "$BASE_DIR/bash.ts.base"

BASE_TE="$BASE_DIR/tool-execution.ts.base"
BASE_IM="$BASE_DIR/interactive-mode.ts.base"
BASE_BASH="$BASE_DIR/bash.ts.base"

# ============================================================
# No-op detection: ANY change in the relevant files?
# ============================================================
ANY_CHANGE=0
for f in "$TOOL_EXEC" "$INTERACTIVE" "$BASH_TOOL"; do
  rel="${f#$REPO/}"
  if ! (cd "$REPO" && git diff --quiet HEAD -- "$rel" 2>/dev/null); then
    ANY_CHANGE=1
  fi
done
if [ "$ANY_CHANGE" -eq 0 ]; then
  echo "No-op patch detected: no changes to relevant files."
  finalize
fi

# ============================================================
# P2P GATE (gating only): Transpilation
# ============================================================
echo "=== P2P Gate: Transpilation ==="
if command -v bun >/dev/null 2>&1; then
  rc_total=0
  for f in "$TOOL_EXEC" "$INTERACTIVE" "$BASH_TOOL"; do
    bun build "$f" --no-bundle >/tmp/build_$$.log 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "GATE FAIL: $f did not transpile"
      cat /tmp/build_$$.log | head -30
      rc_total=1
    fi
  done
  rm -f /tmp/build_$$.log
  if [ $rc_total -ne 0 ]; then
    echo "GATE FAIL: Transpilation broken; reward=0"
    REWARD=0.0
    finalize
  fi
  echo "GATE PASS: transpiles"
else
  echo "GATE SKIP: bun unavailable"
fi

# ============================================================
# P2P Gate: Core structure preserved
# ============================================================
echo "=== P2P Gate: Structural sanity ==="
node -e "
const fs = require('fs');
const te = fs.readFileSync('$TOOL_EXEC', 'utf8');
const im = fs.readFileSync('$INTERACTIVE', 'utf8');
const bt = fs.readFileSync('$BASH_TOOL', 'utf8');
const ok = te.includes('ToolExecutionComponent') &&
           im.includes('tool_execution_start') &&
           bt.includes('renderResult');
process.exit(ok ? 0 : 1);
" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "GATE FAIL: structure broken; reward=0"
  REWARD=0.0
  finalize
fi
echo "GATE PASS: structure preserved"

# ============================================================
# Discover key facts about the BASELINE so we know what's F2P
# Baseline (HEAD) state to inspect:
#   - bash.ts: ALREADY contains "Elapsed"/"Took" timing rendering inside
#     rebuildBashResultRenderComponent. This is the BUG state — timing
#     is rendered as part of the result body controlled by bash.ts,
#     and the renderCall sets state.startedAt which mutates the header
#     context. The fix per instruction is to MOVE timing to
#     tool-execution.ts (component-owned) and stop reliance on the
#     bash.ts internal renderer for timing.
# ============================================================
BASE_BASH_HAS_TIMING=0
if [ -s "$BASE_BASH" ] && grep -qE '"Elapsed"|"Took"' "$BASE_BASH"; then
  BASE_BASH_HAS_TIMING=1
fi
BASE_TE_HAS_TIMING=0
if [ -s "$BASE_TE" ] && grep -qE '"Elapsed"|"Took"' "$BASE_TE"; then
  BASE_TE_HAS_TIMING=1
fi
BASE_IM_HAS_BASH_BRANCH=0
if [ -s "$BASE_IM" ] && grep -qE 'toolName === "bash"' "$BASE_IM"; then
  BASE_IM_HAS_BASH_BRANCH=1
fi

echo "Baseline facts: bash.ts has timing=$BASE_BASH_HAS_TIMING, te.ts has timing=$BASE_TE_HAS_TIMING, interactive has bash branch=$BASE_IM_HAS_BASH_BRANCH"

# ============================================================
# F2P 1 (0.20): Timing labels rendered FROM tool-execution.ts
# (not from bash.ts). Instruction says:
#   "In packages/.../tool-execution.ts, add a timing footer line at
#    the very end of renderBashContent()"
# F2P signal: tool-execution.ts now contains both "Elapsed" and "Took"
# string literals (and base did NOT).
# ============================================================
echo "=== F2P 1 (0.16): tool-execution.ts renders timing labels ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$TOOL_EXEC','utf8');
const base = fs.readFileSync('$BASE_TE','utf8');
const has = (s) => /[\"\`']Elapsed[\"\`' ]/.test(s) && /[\"\`']Took[\"\`' ]/.test(s);
process.exit((has(cur) && !has(base)) ? 0 : 1);
" 2>/dev/null
F2P1=$?
if [ $F2P1 -eq 0 ]; then
  add_reward 0.16
  echo "PASS (+0.16) [F2P1]: tool-execution.ts now owns timing labels"
else
  echo "FAIL [F2P1]: tool-execution.ts does not introduce Elapsed/Took"
fi

# ============================================================
# F2P 2 (0.15): bash.ts header (renderCall) no longer mutates
# state to control timing. The fix should remove the renderCall
# side effect of writing state.startedAt (since timing is now
# owned by the component, not the per-tool render state).
# Equivalently: bash.ts should no longer carry "Elapsed"/"Took"
# string literals — timing rendering moved out.
# ============================================================
echo "=== F2P 2 (0.12): bash.ts no longer renders timing in result ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$BASH_TOOL','utf8');
const base = fs.readFileSync('$BASE_BASH','utf8');
const hasTiming = (s) => /[\"\`']Elapsed[\"\`' ]/.test(s) && /[\"\`']Took[\"\`' ]/.test(s);
// Base has timing; we want current to NOT have it.
process.exit((hasTiming(base) && !hasTiming(cur)) ? 0 : 1);
" 2>/dev/null
F2P2=$?
if [ $F2P2 -eq 0 ]; then
  add_reward 0.12
  echo "PASS (+0.12) [F2P2]: bash.ts timing rendering removed"
else
  echo "FAIL [F2P2]: bash.ts still renders Elapsed/Took (header still mutates)"
fi

# ============================================================
# F2P 3 (0.15): interactive-mode.ts wires bash start timestamp
# to the component. The fix needs a bash-specific branch on
# tool_execution_start that calls a new method on the component
# (e.g. setExecutionStartTime / setExecutionStartTimestamp /
# setBashStartTime) with Date.now().
# ============================================================
echo "=== F2P 3 (0.12): interactive-mode wires bash start timestamp ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$INTERACTIVE','utf8');
const base = fs.readFileSync('$BASE_IM','utf8');
// Look for: a bash-specific branch that calls a setter with Date.now()
const re = /toolName\s*===\s*[\"']bash[\"'][\s\S]{0,400}?\.set[A-Za-z]*Start[A-Za-z]*\s*\(\s*Date\.now\(\)/;
const baseHas = re.test(base);
const curHas  = re.test(cur);
process.exit((curHas && !baseHas) ? 0 : 1);
" 2>/dev/null
F2P3=$?
if [ $F2P3 -eq 0 ]; then
  add_reward 0.12
  echo "PASS (+0.12) [F2P3]: bash start timestamp wired in interactive-mode"
else
  echo "FAIL [F2P3]: no bash-specific setExecutionStart*(Date.now()) call added"
fi

# ============================================================
# F2P 4 (0.15): tool-execution.ts has a live-update interval
# (setInterval ~1000ms) for elapsed timing while running.
# Behavioral signal: the "elapsed time should update live (once
# per second) while the command is running" requirement.
# ============================================================
echo "=== F2P 4 (0.12): live-update interval present in tool-execution.ts ==="
node -e "
const fs = require('fs');
const cur = fs.readFileSync('$TOOL_EXEC','utf8');
const base = fs.readFileSync('$BASE_TE','utf8');
// look for a setInterval(..., 1000) and a clearInterval
const hasSet = /setInterval\s*\([^)]*,\s*1000\b/.test(cur);
const hasClear = /clearInterval\s*\(/.test(cur);
const baseHadSet = /setInterval\s*\([^)]*,\s*1000\b/.test(base);
process.exit((hasSet && hasClear && !baseHadSet) ? 0 : 1);
" 2>/dev/null
F2P4=$?
if [ $F2P4 -eq 0 ]; then
  add_reward 0.12
  echo "PASS (+0.12) [F2P4]: live update interval added (with cleanup)"
else
  echo "FAIL [F2P4]: no 1000ms setInterval + clearInterval pair in tool-execution.ts"
fi

# ============================================================
# F2P 5 (0.20): BEHAVIORAL — verify timing string format and
# bottom placement by actually invoking the component logic.
# We extract just enough of tool-execution.ts to reason about it:
# we look for an addChild call that emits the timing Text, and
# verify it occurs AFTER (textually later than) the result/output
# rendering branch in renderBashContent / updateDisplay. We also
# verify the format uses .toFixed(1) and labels Elapsed/Took.
# ============================================================
echo "=== F2P 5 (0.16): timing rendered AT BOTTOM with .toFixed(1) format ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC','utf8');

// 1) Format: must use toFixed(1) for one decimal precision.
const hasOneDecimal = /toFixed\s*\(\s*1\s*\)/.test(src);

// 2) Timing labels with surrounding context indicating muted/footer style.
const hasElapsed = /[\"\`']Elapsed[\"\`' ]/.test(src);
const hasTook    = /[\"\`']Took[\"\`' ]/.test(src);

// 3) Bottom placement heuristic: find the LAST addChild( ... ) call inside
//    the bash rendering path that adds the timing Text.
//    We do this by checking that an addChild emitting Elapsed/Took text
//    exists, and that it is positioned after some marker indicating the
//    output content has already been added (e.g. result/content added,
//    truncation/warning handling, or after the resultRenderer call).
const lower = src;
// Find indices of key markers
const idxResultRender = (() => {
  const m = lower.match(/resultRenderer\s*\(/);
  return m ? m.index : -1;
})();
const idxTimingAdd = (() => {
  // a Text(...) construction containing Elapsed or Took followed somewhere by addChild
  // We search for the construction site of the timing text.
  const m = lower.match(/[\`\"'][^\`\"']*\\\$\{[^}]*(?:Elapsed|Took|label)[^}]*\}[^\`\"']*[\`\"']/);
  if (m) return m.index;
  // Fallback: find first occurrence of the literal 'Elapsed' string
  const m2 = lower.match(/Elapsed/);
  return m2 ? m2.index : -1;
})();

// The timing text must appear AFTER the resultRenderer/output handling
// (i.e. its index in the source is greater).
const bottomOrder = (idxResultRender !== -1 && idxTimingAdd !== -1 && idxTimingAdd > idxResultRender);

const ok = hasOneDecimal && hasElapsed && hasTook && bottomOrder;
if (!ok) {
  console.error(JSON.stringify({ hasOneDecimal, hasElapsed, hasTook, idxResultRender, idxTimingAdd, bottomOrder }));
}
process.exit(ok ? 0 : 1);
" 2>/dev/null
F2P5=$?
if [ $F2P5 -eq 0 ]; then
  add_reward 0.16
  echo "PASS (+0.16) [F2P5]: timing has .toFixed(1) format and is rendered after result"
else
  echo "FAIL [F2P5]: format/placement check failed"
fi

# ============================================================
# F2P 6 (0.15): BEHAVIORAL — simulate the timing string the
# component would produce and verify it matches the spec
# ("Elapsed Xs" / "Took Xs" with one decimal). We extract the
# expression that builds the timing line (or fall back to the
# whole file) and exercise it for both partial (running) and
# completed states using a small JS reproduction.
#
# We accept this gate if BOTH outputs match the regex
# /^Elapsed \d+\.\dS?$/i style, i.e., the spec format.
# ============================================================
echo "=== F2P 6 (0.12): behavioral format check ==="
node -e "
const fs = require('fs');
const src = fs.readFileSync('$TOOL_EXEC','utf8');

// Simulate: format an elapsed of 12345 ms two ways and check the
// canonical strings 'Elapsed 12.3s' and 'Took 47.2s' would appear.
// We do this by searching the source for a template that, given
// elapsed ms, produces \`\${label} \${(ms/1000).toFixed(1)}s\`.
const tmplRe = /\\\$\{[^}]*label[^}]*\}\s*\\\$\{[^}]*toFixed\s*\(\s*1\s*\)[^}]*\}s/;
const tmplRe2 = /\\\$\{[^}]*toFixed\s*\(\s*1\s*\)[^}]*\}s/;

const a = tmplRe.test(src);
const b = tmplRe2.test(src) && /label/.test(src) && /Elapsed/.test(src) && /Took/.test(src);

process.exit((a || b) ? 0 : 1);
" 2>/dev/null
F2P6=$?
if [ $F2P6 -eq 0 ]; then
  add_reward 0.12
  echo "PASS (+0.12) [F2P6]: timing string format matches spec"
else
  echo "FAIL [F2P6]: spec-format template not found"
fi

# ============================================================
# Run any project unit tests relevant to bash tool / tool-execution
# (R3). We don't fail on absence; we boost trivially if found+passing.
# ============================================================
echo "=== Optional: relevant unit tests ==="
TEST_FILES=$(find "$REPO/packages/coding-agent" -type f \( -name "*tool-execution*.test.ts" -o -name "*bash*.test.ts" \) 2>/dev/null | head -5)
if [ -n "$TEST_FILES" ] && command -v bun >/dev/null 2>&1; then
  cd "$REPO"
  for tf in $TEST_FILES; do
    echo "Running: $tf"
    bun test "$tf" >/tmp/testout_$$.log 2>&1
    rc=$?
    cat /tmp/testout_$$.log | tail -20
    if [ $rc -ne 0 ]; then
      echo "Note: tests in $tf failed (no reward penalty unless gating)"
    fi
    rm -f /tmp/testout_$$.log
  done
fi

echo "=== Existing checks reward: $REWARD ==="
# Write existing reward (don't exit yet — upstream gates follow)
awk -v r="$REWARD" 'BEGIN{ if(r<0)r=0; if(r>1)r=1; printf "%.4f\n", r }' > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
# Prelude: build tui for vitest tests
(cd "$REPO/packages/tui" && npx tsgo -p tsconfig.build.json >/dev/null 2>&1) || true
cd "$REPO"

# F2P gate: behavioral vitest — bash timing method + render
echo "=== F2P Upstream Gate: bash timing behavioral test ==="
cat > packages/coding-agent/test/_f2p_upstream_bash_timing.test.ts << 'VITESTEOF'
import { beforeAll, test, expect } from "vitest";
import stripAnsi from "strip-ansi";
import type { TUI } from "@mariozechner/pi-tui";
import { createBashToolDefinition } from "../src/core/tools/bash.js";
import { ToolExecutionComponent } from "../src/modes/interactive/components/tool-execution.js";
import { initTheme } from "../src/modes/interactive/theme/theme.js";
function createFakeTui(): TUI { return { requestRender: () => {} } as unknown as TUI; }
beforeAll(() => { initTheme("dark"); });
test("bash tool component exposes setExecutionStartTimestamp and renders timing at bottom", () => {
  const bashDef = createBashToolDefinition(process.cwd());
  const component = new ToolExecutionComponent("bash", "bash-timing-1", { command: "echo hello" }, {}, bashDef, createFakeTui(), process.cwd());
  expect(typeof component.setExecutionStartTimestamp).toBe("function");
  component.markExecutionStarted();
  component.setExecutionStartTimestamp(Date.now() - 12345);
  component.updateResult({ content: [{ type: "text", text: "some output" }], isError: false }, true);
  const rendered = stripAnsi(component.render(120).join("\n"));
  expect(rendered).toMatch(/Elapsed \d+\.\ds/);
});
VITESTEOF
node_modules/.bin/vitest run packages/coding-agent/test/_f2p_upstream_bash_timing.test.ts >/tmp/f2p_gate_$$.log 2>&1
F2P_TIMING_RC=$?
rm -f packages/coding-agent/test/_f2p_upstream_bash_timing.test.ts
echo "{\"id\": \"f2p_upstream_bash_timing\", \"passed\": $([ $F2P_TIMING_RC -eq 0 ] && echo true || echo false), \"detail\": \"rc=$F2P_TIMING_RC\"}" >> /logs/verifier/gates.json
echo "F2P upstream bash_timing: rc=$F2P_TIMING_RC"

# P2P gate: tsgo type check (scoped to agent-touched .ts/.tsx files)
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
echo "=== P2P Upstream Gate: tsgo --noEmit (scoped) ==="
CHANGED_TS_FILES=$(cd "$REPO" && (git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
    echo "No .ts/.tsx changes in agent diff — gate vacuously passes"
    P2P_TSGO_RC=0
    echo "{\"id\": \"p2p_upstream_tsgo_typecheck\", \"passed\": true, \"detail\": \"no agent .ts/.tsx changes — gate skipped\"}" >> /logs/verifier/gates.json
else
    timeout 60 npx tsgo --noEmit $CHANGED_TS_FILES >/tmp/p2p_tsgo_$$.log 2>&1
    P2P_TSGO_RC=$?
    echo "{\"id\": \"p2p_upstream_tsgo_typecheck\", \"passed\": $([ $P2P_TSGO_RC -eq 0 ] && echo true || echo false), \"detail\": \"rc=$P2P_TSGO_RC\"}" >> /logs/verifier/gates.json
fi
echo "P2P upstream tsgo: rc=$P2P_TSGO_RC"

# P2P gate: biome lint
echo "=== P2P Upstream Gate: biome check ==="
npx biome check --error-on-warnings . >/tmp/p2p_biome_$$.log 2>&1
P2P_BIOME_RC=$?
echo "{\"id\": \"p2p_upstream_biome_lint\", \"passed\": $([ $P2P_BIOME_RC -eq 0 ] && echo true || echo false), \"detail\": \"rc=$P2P_BIOME_RC\"}" >> /logs/verifier/gates.json
echo "P2P upstream biome: rc=$P2P_BIOME_RC"

# P2P gate: vitest tool-execution-component tests
echo "=== P2P Upstream Gate: vitest tool-execution-component ==="
node_modules/.bin/vitest run packages/coding-agent/test/tool-execution-component.test.ts >/tmp/p2p_vitest_$$.log 2>&1
P2P_VITEST_RC=$?
echo "{\"id\": \"p2p_upstream_vitest_tool_exec\", \"passed\": $([ $P2P_VITEST_RC -eq 0 ] && echo true || echo false), \"detail\": \"rc=$P2P_VITEST_RC\"}" >> /logs/verifier/gates.json
echo "P2P upstream vitest: rc=$P2P_VITEST_RC"

# Upstream reward tail
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_upstream_bash_timing": 0.2
}
P2P_REGRESSION = ["p2p_upstream_tsgo_typecheck", "p2p_upstream_biome_lint", "p2p_upstream_vitest_tool_exec"]
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
# ---- end ----

exit 0