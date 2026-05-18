#!/usr/bin/env bash
# Verifier — cli-task-b3d2dd: Fix `(no prompt)` for multi-session checkpoints.
#
# Bug #3 in docs/plans/2026-03-05-explain-bugs.md: when a checkpoint has multiple
# sessions and the latest session lacks a prompt.txt, ReadLatestSessionPromptFromCommittedTree
# returned "" instead of falling back through earlier sessions. The canonical
# fix (entireio/cli @ f7a13512..., parent 56cdda51) replaces the single-shot
# lookup with a descending loop that walks i := latestIndex; i >= 0; i-- and
# returns the first non-empty extracted prompt.
#
# We inject a verifier-only Go test file at evaluation time, run it against
# the agent's modified common.go, and use individual subtest pass/fail as
# behavioral F2P gates. Five F2P gates (sum 1.00) + 1 informational P2P_REGRESSION.
# Reward formula is weighted-replace per CLAUDE.md scoring rules.
#
# Buggy baseline scores ≤ 0.10 (only G5_REGRESSION_EXISTING — the existing 7
# subtests were designed for the buggy state and continue to pass).
# Canonical fix scores 1.00.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/workspace/cli}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

COMMON_GO="$REPO/cmd/entire/cli/strategy/common.go"
STRATEGY_DIR="$REPO/cmd/entire/cli/strategy"
INJECTED_TEST="$STRATEGY_DIR/zzz_b3d2dd_verifier_test.go"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

if [ ! -f "$COMMON_GO" ]; then
    echo "ERROR: $COMMON_GO not found" >&2
    echo 0.0 > "$REWARD_FILE"
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# Inject verifier-only canonical-behavior test file. Lives in the same
# package (`strategy`) so it can use the package-internal `buildCommittedTree`
# helper from common_test.go.
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INJECTED_TEST" <<'GOEOF'
package strategy

import (
	"testing"

	"github.com/entireio/cli/cmd/entire/cli/checkpoint/id"
)

// Verifier-injected canonical test cases for cli-task-b3d2dd.
// Exercises bug #3 in docs/plans/2026-03-05-explain-bugs.md: the prompt
// fallback through earlier sessions when the latest session has no prompt.

func TestB3d2ddCanonical(t *testing.T) {
	t.Parallel()

	cpID := id.MustCheckpointID("a3b2c4d5e6f7")

	t.Run("fallback_latest_no_prompt", func(t *testing.T) {
		t.Parallel()
		tree := buildCommittedTree(t, map[string]string{
			"a3/b2c4d5e6f7/0/prompt.txt":    "Real session prompt",
			"a3/b2c4d5e6f7/1/metadata.json": `{"session_id":"test"}`,
		})
		got := ReadLatestSessionPromptFromCommittedTree(tree, cpID, 2)
		if got != "Real session prompt" {
			t.Errorf("got %q, want %q", got, "Real session prompt")
		}
	})

	t.Run("fallback_through_multiple_empty", func(t *testing.T) {
		t.Parallel()
		tree := buildCommittedTree(t, map[string]string{
			"a3/b2c4d5e6f7/0/prompt.txt":    "Original prompt",
			"a3/b2c4d5e6f7/1/metadata.json": `{"session_id":"s1"}`,
			"a3/b2c4d5e6f7/2/metadata.json": `{"session_id":"s2"}`,
		})
		got := ReadLatestSessionPromptFromCommittedTree(tree, cpID, 3)
		if got != "Original prompt" {
			t.Errorf("got %q, want %q", got, "Original prompt")
		}
	})

	t.Run("returns_empty_no_prompt", func(t *testing.T) {
		t.Parallel()
		tree := buildCommittedTree(t, map[string]string{
			"a3/b2c4d5e6f7/0/metadata.json": `{"session_id":"s0"}`,
			"a3/b2c4d5e6f7/1/metadata.json": `{"session_id":"s1"}`,
		})
		got := ReadLatestSessionPromptFromCommittedTree(tree, cpID, 2)
		if got != "" {
			t.Errorf("got %q, want empty string", got)
		}
	})

	t.Run("fallback_empty_prompt_file", func(t *testing.T) {
		t.Parallel()
		tree := buildCommittedTree(t, map[string]string{
			"a3/b2c4d5e6f7/0/prompt.txt": "Real prompt",
			"a3/b2c4d5e6f7/1/prompt.txt": "",
		})
		got := ReadLatestSessionPromptFromCommittedTree(tree, cpID, 2)
		if got != "Real prompt" {
			t.Errorf("got %q, want %q", got, "Real prompt")
		}
	})
}
GOEOF

# ──────────────────────────────────────────────────────────────────────────────
# Run injected canonical tests + existing prompt tests. Capture full output.
# ──────────────────────────────────────────────────────────────────────────────
TEST_LOG="$LOGS_DIR/go_test.log"
go test -count=1 -timeout 90s -v \
    -run 'TestB3d2ddCanonical|TestReadLatestSessionPromptFromCommittedTree' \
    ./cmd/entire/cli/strategy/ > "$TEST_LOG" 2>&1
GO_TEST_RC=$?

echo "[verifier] go test rc=$GO_TEST_RC; log tail:"
tail -30 "$TEST_LOG"

# Parse pass/fail per subtest
parse_subtest() {
    # Args: subtest leaf name (e.g. fallback_latest_no_prompt)
    local leaf="$1"
    if grep -qE "^[[:space:]]*--- PASS:[[:space:]]+TestB3d2ddCanonical/${leaf}\b" "$TEST_LOG"; then
        echo "true"
    else
        echo "false"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# G1 (F2P_FALLBACK_LATEST_NO_PROMPT, weight 0.30):
#   Function falls back from latest session (no prompt.txt) to an earlier
#   session that has prompt.txt. This is the headline bug. Both buggy and
#   canonical states are exercised by an injected test that constructs a
#   2-session checkpoint where session 1 has only metadata.json (no prompt).
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=$(parse_subtest "fallback_latest_no_prompt")
echo "[G1_FALLBACK_LATEST_NO_PROMPT] pass=$G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G2 (F2P_FALLBACK_THROUGH_MULTIPLE_EMPTY, weight 0.25):
#   Function falls back through multiple consecutive empty sessions to find
#   a prompt. Confirms the iterative loop (not just a single fallback).
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=$(parse_subtest "fallback_through_multiple_empty")
echo "[G2_FALLBACK_THROUGH_MULTIPLE_EMPTY] pass=$G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G3 (F2P_FALLBACK_EMPTY_PROMPT_FILE, weight 0.20):
#   Function falls back when latest session has prompt.txt but it's empty.
#   Detects the subtle behavior where empty content must be treated like
#   "no prompt" rather than returning "". An agent who only handles missing
#   prompt.txt (but not empty content) will fail this gate.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=$(parse_subtest "fallback_empty_prompt_file")
echo "[G3_FALLBACK_EMPTY_PROMPT_FILE] pass=$G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G4 (F2P_REGRESSION_EXISTING, weight 0.10):
#   All 7 existing TestReadLatestSessionPromptFromCommittedTree subtests still
#   pass. Catches solutions that break the original behavior while patching
#   the fallback path. Note: this gate ALSO passes on the buggy baseline
#   (the existing tests were designed for the buggy code), so it's worth a
#   modest weight — its real value is regression-catching, not differentiation.
# ──────────────────────────────────────────────────────────────────────────────
EXISTING_PASS_COUNT=$(grep -cE '^[[:space:]]*--- PASS:[[:space:]]+TestReadLatestSessionPromptFromCommittedTree/' "$TEST_LOG")
EXISTING_FAIL_COUNT=$(grep -cE '^[[:space:]]*--- FAIL:[[:space:]]+TestReadLatestSessionPromptFromCommittedTree/' "$TEST_LOG")
if [ "$EXISTING_FAIL_COUNT" = "0" ] && [ "$EXISTING_PASS_COUNT" -ge 6 ]; then
    G4_PASS=true
else
    G4_PASS=false
fi
echo "[G4_REGRESSION_EXISTING] existing pass=$EXISTING_PASS_COUNT fail=$EXISTING_FAIL_COUNT → pass=$G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G5 (F2P_NOT_STUB, weight 0.15):
#   ReadLatestSessionPromptFromCommittedTree body is non-trivial: contains
#   a loop construct (`for `), at least one access to sessionCount or an
#   index variable, and >= 8 non-blank lines (Go single-line comments stripped).
#   The buggy code lacks the loop, so this is a real differentiator. Catches
#   degenerate `return ""` stubs that would silently pass G3.
# ──────────────────────────────────────────────────────────────────────────────
G5_PASS=false
G5_RES=$(python3 - "$COMMON_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+ReadLatestSessionPromptFromCommittedTree\s*\(', src)
if not m:
    print("FAIL: function not found"); sys.exit(0)
i = m.end()
paren_depth = 1
while i < len(src) and paren_depth > 0:
    if src[i] == '(': paren_depth += 1
    elif src[i] == ')': paren_depth -= 1
    i += 1
brace = src.find('{', i)
if brace < 0:
    print("FAIL: body open brace missing"); sys.exit(0)
depth = 1; j = brace + 1
while j < len(src) and depth > 0:
    if src[j] == '{': depth += 1
    elif src[j] == '}': depth -= 1
    j += 1
body = src[brace+1:j-1]
# Strip Go single-line comments (not block comments — none here) so they don't
# count as meaningful lines.
body_no_comments = re.sub(r'//[^\n]*', '', body)
non_blank = [ln for ln in body_no_comments.splitlines() if ln.strip()]
has_loop = re.search(r'\bfor\s', body_no_comments) is not None
has_index_use = (re.search(r'\bsessionCount\b', body_no_comments) is not None
                 or re.search(r'strconv\.Itoa\s*\(', body_no_comments) is not None
                 or re.search(r'cpTree\.Tree\s*\(', body_no_comments) is not None)
ok = has_loop and has_index_use and len(non_blank) >= 8
print(f"loop={has_loop} index_use={has_index_use} non_blank_lines={len(non_blank)} -> "
      f"{'PASS' if ok else 'FAIL'}")
PYEOF
)
[[ "$G5_RES" == *PASS ]] && G5_PASS=true
echo "[G5_NOT_STUB] $G5_RES → pass=$G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# P2P_REGRESSION (informational): `go build ./cmd/entire/...` succeeds. Both
# buggy and canonical states build, so this is logged for diagnostics but
# never affects the score (per CLAUDE.md scoring rules).
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
    "F2P_FALLBACK_LATEST_NO_PROMPT",
    "F2P_FALLBACK_THROUGH_MULTIPLE_EMPTY",
    "F2P_FALLBACK_EMPTY_PROMPT_FILE",
    "F2P_REGRESSION_EXISTING",
    "F2P_NOT_STUB",
]
p2p_ids = ["P2P_GO_BUILD"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(f2p_ids, f2p_verdicts)]
gates += [{"id": gid, "pass": v, "kind": "P2P_REGRESSION"} for gid, v in zip(p2p_ids, p2p_verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# F2P weight sum = 1.00 (full replacement; legacy reward fully subsumed).
# P2P_REGRESSION is informational only — `p2p_failed = False` ALWAYS.
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
    "F2P_FALLBACK_LATEST_NO_PROMPT":       0.30,
    "F2P_FALLBACK_THROUGH_MULTIPLE_EMPTY": 0.25,
    "F2P_FALLBACK_EMPTY_PROMPT_FILE":      0.20,
    "F2P_REGRESSION_EXISTING":             0.10,
    "F2P_NOT_STUB":                        0.15,
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
echo "  F2P_FALLBACK_LATEST_NO_PROMPT       = $G1_PASS  (weight 0.30)"
echo "  F2P_FALLBACK_THROUGH_MULTIPLE_EMPTY = $G2_PASS  (weight 0.25)"
echo "  F2P_FALLBACK_EMPTY_PROMPT_FILE      = $G3_PASS  (weight 0.20)"
echo "  F2P_REGRESSION_EXISTING             = $G4_PASS  (weight 0.10)"
echo "  F2P_NOT_STUB                        = $G5_PASS  (weight 0.15)"
echo "  [P2P] GO_BUILD                      = $P1_PASS  (informational only)"
echo "Final reward: $reward"
cat "$REWARD_FILE"

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
