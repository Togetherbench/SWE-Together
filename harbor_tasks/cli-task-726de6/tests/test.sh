#!/usr/bin/env bash
# Verifier — cli-task-726de6: Factory AI Droid welcome-message bug.
#
# The bug: when the agent is Factory AI Droid (not Claude Code), the lifecycle
# session-start handler unconditionally calls `outputHookResponse(message)`,
# which JSON-encodes `{"systemMessage":"..."}` to stdout. Factory's terminal
# does NOT parse that JSON — so users see the raw `{"systemMessage":"..."}`
# string in their terminal.
#
# Canonical fix (commit 8118d5e on entireio/cli, parent 7f1cdc8c):
#   1. Define a new `HookResponseWriter` interface in `cmd/entire/cli/agent/agent.go`
#      with method `WriteHookResponse(message string) error`.
#   2. Implement it on `*ClaudeCodeAgent` (claudecode/lifecycle.go) — JSON-encodes
#      a `{"systemMessage": ...}` struct via json.NewEncoder(os.Stdout).
#   3. Implement it on `*FactoryAIDroidAgent` (factoryaidroid/lifecycle.go) —
#      writes plain text via fmt.Fprintln(os.Stdout, message). NO json.
#   4. Replace the unconditional `outputHookResponse(message)` call in
#      `cmd/entire/cli/lifecycle.go` with a type-assertion gate:
#      `if writer, ok := ag.(agent.HookResponseWriter); ok { writer.WriteHookResponse(...) }`
#   5. Remove the now-dead `outputHookResponse` helper + `hookResponse` struct
#      from `cmd/entire/cli/hooks.go`.
#
# Five F2P gates (sum 1.00) + 1 informational P2P_REGRESSION. All gates are
# behavioral (interface-shape and call-site refactor) and grep/AST-style on
# Go source with line+block comments stripped before matching, so docstring
# mentions of `outputHookResponse` won't accidentally pass/fail any gate.
#
# Reward formula: weighted-replace per CLAUDE.md scoring rules.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/repo}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

AGENT_GO="$REPO/cmd/entire/cli/agent/agent.go"
CC_GO="$REPO/cmd/entire/cli/agent/claudecode/lifecycle.go"
FA_GO="$REPO/cmd/entire/cli/agent/factoryaidroid/lifecycle.go"
HOOKS_GO="$REPO/cmd/entire/cli/hooks.go"
LIFE_GO="$REPO/cmd/entire/cli/lifecycle.go"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

# Sanity: every source file must exist
for f in "$AGENT_GO" "$CC_GO" "$FA_GO" "$HOOKS_GO" "$LIFE_GO"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found" >&2
        echo 0.0 > "$REWARD_FILE"
        exit 0
    fi
done

# ──────────────────────────────────────────────────────────────────────────────
# G1 (F2P_HRW_INTERFACE_DEFINED, weight 0.25):
#   `cmd/entire/cli/agent/agent.go` defines a top-level interface named
#   `HookResponseWriter` containing a method `WriteHookResponse(<...> string) <...> error`.
#   Implementation-agnostic on the parameter name; we just require:
#     - `type HookResponseWriter interface { ... }`
#     - inside that interface body, a method whose signature mentions
#       `WriteHookResponse(` and ends with `error`.
#   Comments are stripped before matching to defeat docstring leakage.
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=false
G1_RES=$(python3 - "$AGENT_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Strip /* … */ block comments and // line comments to avoid matching prose.
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
src = re.sub(r'//[^\n]*', '', src)
m = re.search(r'type\s+HookResponseWriter\s+interface\s*\{', src)
if not m:
    print("FAIL: no `type HookResponseWriter interface` declaration"); sys.exit(0)
# Walk to matching `}` to extract the body.
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]
# Method signature inside interface body: `WriteHookResponse(... string ...) error`
sig = re.search(r'WriteHookResponse\s*\([^)]*\bstring\b[^)]*\)\s*error\b', body)
if sig:
    print("PASS")
else:
    print("FAIL: HookResponseWriter has no WriteHookResponse(... string) error method")
PYEOF
)
[[ "$G1_RES" == PASS* ]] && G1_PASS=true
echo "[G1_HRW_INTERFACE_DEFINED] $G1_RES → pass=$G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G2 (F2P_OLD_HELPER_REMOVED, weight 0.20):
#   `cmd/entire/cli/hooks.go` no longer defines the old `outputHookResponse`
#   helper or the `hookResponse` struct. Comments stripped before matching.
#   Behavioral: the dead helper should be deleted (else lifecycle.go path was
#   not migrated to the interface; the canonical patch deletes both).
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=false
G2_RES=$(python3 - "$HOOKS_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
src = re.sub(r'//[^\n]*', '', src)
has_helper = bool(re.search(r'\bfunc\s+outputHookResponse\s*\(', src))
has_struct = bool(re.search(r'\btype\s+hookResponse\s+struct\b', src))
if not has_helper and not has_struct:
    print("PASS")
else:
    bits = []
    if has_helper: bits.append("outputHookResponse(...) helper still defined")
    if has_struct: bits.append("hookResponse struct still defined")
    print("FAIL: " + "; ".join(bits))
PYEOF
)
[[ "$G2_RES" == PASS* ]] && G2_PASS=true
echo "[G2_OLD_HELPER_REMOVED] $G2_RES → pass=$G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G3 (F2P_LIFECYCLE_TYPE_ASSERT, weight 0.20):
#   `cmd/entire/cli/lifecycle.go` calls into `HookResponseWriter` via a Go
#   type-assertion (`.(agent.HookResponseWriter)`) AND no longer calls the
#   old `outputHookResponse(` helper. Either replacement variant is OK
#   (`.(agent.HookResponseWriter)` or just `.(HookResponseWriter)` if same pkg)
#   — we accept both.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=false
G3_RES=$(python3 - "$LIFE_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
src = re.sub(r'//[^\n]*', '', src)
has_type_assert = bool(re.search(r'\.\(\s*(?:agent\.)?HookResponseWriter\s*\)', src))
calls_writehook = bool(re.search(r'\bWriteHookResponse\s*\(', src))
calls_old_helper = bool(re.search(r'\boutputHookResponse\s*\(', src))
ok = has_type_assert and calls_writehook and (not calls_old_helper)
print(f"type_assert={has_type_assert} calls_WriteHookResponse={calls_writehook} "
      f"calls_outputHookResponse={calls_old_helper} -> "
      f"{'PASS' if ok else 'FAIL'}")
PYEOF
)
[[ "$G3_RES" == *PASS ]] && G3_PASS=true
echo "[G3_LIFECYCLE_TYPE_ASSERT] $G3_RES → pass=$G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G4 (F2P_CC_IMPL_JSON, weight 0.15):
#   `cmd/entire/cli/agent/claudecode/lifecycle.go` defines a `WriteHookResponse`
#   method receiver AND its body emits JSON via `json.NewEncoder(...)` (or
#   `json.Marshal`) AND mentions a `systemMessage` field/tag.
#   This pins the CC-side spec: JSON with systemMessage payload.
# ──────────────────────────────────────────────────────────────────────────────
G4_PASS=false
G4_RES=$(python3 - "$CC_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
src = re.sub(r'//[^\n]*', '', src)
m = re.search(r'func\s+\([^)]+\)\s+WriteHookResponse\s*\(', src)
if not m:
    print("FAIL: no func receiver WriteHookResponse on ClaudeCodeAgent"); sys.exit(0)
# Walk to matching `}` to extract the method body.
brace = src.find('{', m.end())
if brace < 0:
    print("FAIL: WriteHookResponse body not found"); sys.exit(0)
i = brace + 1; depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[brace+1:i-1]
uses_json = bool(re.search(r'json\.(NewEncoder|Marshal)\s*\(', body))
mentions_system_msg = bool(re.search(r'systemMessage|SystemMessage', body))
ok = uses_json and mentions_system_msg
print(f"json_encode={uses_json} systemMessage={mentions_system_msg} -> "
      f"{'PASS' if ok else 'FAIL'}")
PYEOF
)
[[ "$G4_RES" == *PASS ]] && G4_PASS=true
echo "[G4_CC_IMPL_JSON] $G4_RES → pass=$G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G5 (F2P_FACTORY_IMPL_PLAINTEXT, weight 0.20):
#   `cmd/entire/cli/agent/factoryaidroid/lifecycle.go` defines a
#   `WriteHookResponse` method receiver AND its body uses a plain-text writer
#   (fmt.Fprintln/Fprintf/Fprint to os.Stdout, or io.WriteString, or
#   os.Stdout.Write/WriteString) AND does NOT JSON-encode (the whole point of
#   the bug fix — Factory must NOT see {"systemMessage":...}).
# ──────────────────────────────────────────────────────────────────────────────
G5_PASS=false
G5_RES=$(python3 - "$FA_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
src = re.sub(r'//[^\n]*', '', src)
m = re.search(r'func\s+\([^)]+\)\s+WriteHookResponse\s*\(', src)
if not m:
    print("FAIL: no func receiver WriteHookResponse on FactoryAIDroidAgent"); sys.exit(0)
brace = src.find('{', m.end())
if brace < 0:
    print("FAIL: WriteHookResponse body not found"); sys.exit(0)
i = brace + 1; depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[brace+1:i-1]
uses_plain = bool(re.search(
    r'fmt\.Fprint(?:ln|f)?\s*\(\s*os\.Stdout|'
    r'io\.WriteString\s*\(\s*os\.Stdout|'
    r'os\.Stdout\.Write(?:String)?\s*\(',
    body))
uses_json = bool(re.search(r'json\.(NewEncoder|Marshal)\s*\(', body))
ok = uses_plain and (not uses_json)
print(f"plain_writer={uses_plain} json_encode={uses_json} -> "
      f"{'PASS' if ok else 'FAIL'}")
PYEOF
)
[[ "$G5_RES" == *PASS ]] && G5_PASS=true
echo "[G5_FACTORY_IMPL_PLAINTEXT] $G5_RES → pass=$G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# P2P_REGRESSION (informational): `go build ./cmd/entire/...` succeeds. Both
# buggy and canonical states pass build (the canonical refactor doesn't break
# compile), so this is logged for diagnostics only and NEVER affects the
# score (per CLAUDE.md scoring rules — `p2p_failed = false` always).
# ──────────────────────────────────────────────────────────────────────────────
BUILD_LOG="$LOGS_DIR/go_build.log"
go build ./cmd/entire/... > "$BUILD_LOG" 2>&1
BUILD_RC=$?
if [ "$BUILD_RC" = "0" ]; then
    P1_PASS=true
else
    P1_PASS=false
    echo "[P2P] go build failed; tail of $BUILD_LOG:"
    tail -20 "$BUILD_LOG"
fi
echo "[P2P_GO_BUILD] (informational) rc=$BUILD_RC → pass=$P1_PASS"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$P1_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
f2p_verdicts = [s == "true" for s in sys.argv[2:7]]
p2p_verdicts = [s == "true" for s in sys.argv[7:8]]
f2p_ids = [
    "F2P_HRW_INTERFACE_DEFINED",
    "F2P_OLD_HELPER_REMOVED",
    "F2P_LIFECYCLE_TYPE_ASSERT",
    "F2P_CC_IMPL_JSON",
    "F2P_FACTORY_IMPL_PLAINTEXT",
]
p2p_ids = ["P2P_GO_BUILD"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(f2p_ids, f2p_verdicts)]
gates += [{"id": gid, "pass": v, "kind": "P2P_REGRESSION"} for gid, v in zip(p2p_ids, p2p_verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# F2P weight sum = 1.00 (full replacement; legacy reward fully subsumed).
# P2P_REGRESSION is informational only (scoring_traps.md / CLAUDE.md):
# `p2p_failed = False` ALWAYS — diagnostic/penalty only on P2P.
existing="0.0"
if [ -f "$LOGS_DIR/base_reward.txt" ]; then
    existing=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")
fi

# F2P: at least one gate must pass for non-zero reward (or existing > 0)
f2p_any_pass=false
for v in "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS"; do
    if [ "$v" = "true" ]; then f2p_any_pass=true; break; fi
done

reward=$(python3 - "$existing" "$f2p_any_pass" \
    "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" <<'PYEOF'
import sys
existing = float(sys.argv[1])
f2p_any_pass = sys.argv[2] == "true"
v = [s == "true" for s in sys.argv[3:8]]
WEIGHTS = {
    "F2P_HRW_INTERFACE_DEFINED":  0.25,
    "F2P_OLD_HELPER_REMOVED":     0.20,
    "F2P_LIFECYCLE_TYPE_ASSERT":  0.20,
    "F2P_CC_IMPL_JSON":           0.15,
    "F2P_FACTORY_IMPL_PLAINTEXT": 0.20,
}
ids = list(WEIGHTS.keys())
verdicts = dict(zip(ids, v))
p2p_failed = False  # P2P_REGRESSION informational only
if p2p_failed or (not f2p_any_pass and existing <= 0):
    print("0.000000")
else:
    inner_weight = max(0.0, 1.0 - sum(WEIGHTS.values()))
    r = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            r += float(w)
    r = max(0.0, min(1.0, r))
    print(f"{r:.6f}")
PYEOF
)

echo "$reward" > "$REWARD_FILE"
echo "─────────────────────────────────────────────────"
echo "Gate verdicts:"
echo "  F2P_HRW_INTERFACE_DEFINED   = $G1_PASS  (weight 0.25)"
echo "  F2P_OLD_HELPER_REMOVED      = $G2_PASS  (weight 0.20)"
echo "  F2P_LIFECYCLE_TYPE_ASSERT   = $G3_PASS  (weight 0.20)"
echo "  F2P_CC_IMPL_JSON            = $G4_PASS  (weight 0.15)"
echo "  F2P_FACTORY_IMPL_PLAINTEXT  = $G5_PASS  (weight 0.20)"
echo "  [P2P] GO_BUILD              = $P1_PASS  (informational only)"
echo "Final reward: $reward"
cat "$REWARD_FILE"
