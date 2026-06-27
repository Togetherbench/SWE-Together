#!/usr/bin/env bash
# Verifier — entireio/cli telemetry detached subprocess fix.
#
# The bug: in cmd/entire/cli/telemetry/detached_unix.go,
# `cmd.Stdout = nil` / `cmd.Stderr = nil` does NOT redirect to /dev/null —
# Go's os/exec treats nil as "inherit parent's descriptors". Any panic /
# stray write from the analytics subprocess therefore leaks to the user's
# CLI terminal. Fix: assign cmd.Stdout/Stderr to a real discard sink
# (io.Discard, ioutil.Discard, or an opened handle to /dev/null).
#
# Canonical patch: 1 file changed, 4 insertions(+), 3 deletions(-)
#   - import "io"
#   - cmd.Stdout = io.Discard
#   - cmd.Stderr = io.Discard
#   - misleading comment replaced
#
# Each F2P gate writes a verdict; weighted-replace formula computes final reward.
# F2P sum = 1.00 (legacy reward fully replaced). P2P_REGRESSION is informational
# only and never zeros the score (per CLAUDE.md / scoring_traps.md).
#
# Discrimination targets:
#   * buggy baseline (HEAD = 65fa5640) → 0.00
#   * canonical patch applied          → 1.00
#
# Anti-overfitting (per SWE-bench Verified critique): we accept any standard
# discard target — io.Discard, ioutil.Discard, or a *os.File opened against
# /dev/null. Exact identifier names from the gold patch are NOT required.

set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/repo
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

SRC="$REPO/cmd/entire/cli/telemetry/detached_unix.go"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 1 (F2P_NIL_REMOVED, weight 0.20):
# The buggy `cmd.Stdout = nil` and `cmd.Stderr = nil` lines must be GONE.
# This is the headline anti-pattern-removed gate.
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=false
NIL_HITS=0
if [ -f "$SRC" ]; then
    NIL_HITS=$(grep -cE '^\s*cmd\.(Stdout|Stderr)\s*=\s*nil\s*(//.*)?$' "$SRC")
    if [ "${NIL_HITS:-0}" = "0" ]; then
        G1_PASS=true
    fi
fi
echo "[gate] F2P_NIL_REMOVED            pass=$G1_PASS  (nil-assignments found: ${NIL_HITS:-0})"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 2 (F2P_STDOUT_DISCARD, weight 0.25):
# cmd.Stdout is assigned to a non-nil discard target. Solution-agnostic regex —
# accepts io.Discard, ioutil.Discard, or any *os.File-shaped variable name
# (e.g., devnull, sink, dev) that the agent might have introduced. Anti-
# overfitting: we don't require the exact symbol from the gold patch.
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=false
if [ -f "$SRC" ]; then
    OUT=$(python3 - "$SRC" "Stdout" <<'PYEOF'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
field = sys.argv[2]
# Solution-agnostic: any non-nil discard target accepted.
discard_re = re.compile(
    r"^\s*cmd\." + field + r"\s*=\s*("
    r"io\.Discard"
    r"|ioutil\.Discard"
    r"|[A-Za-z_][A-Za-z_0-9.]*"          # var or qualified name (e.g. devnull, sink, x.Out)
    r")\b",
    re.MULTILINE,
)
targets = [m.group(1) for m in discard_re.finditer(src) if m.group(1) != "nil"]
print("PASS" if targets else f"FAIL: targets={targets}")
PYEOF
)
    if [[ "$OUT" == "PASS"* ]]; then G2_PASS=true; fi
fi
echo "[gate] F2P_STDOUT_DISCARD         pass=$G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 3 (F2P_STDERR_DISCARD, weight 0.25):
# cmd.Stderr is assigned to a non-nil discard target. Same logic as Gate 2 but
# for the stderr field. Splitting Stdout/Stderr into separate gates gives
# partial credit for half-finished fixes.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=false
if [ -f "$SRC" ]; then
    OUT=$(python3 - "$SRC" "Stderr" <<'PYEOF'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
field = sys.argv[2]
discard_re = re.compile(
    r"^\s*cmd\." + field + r"\s*=\s*("
    r"io\.Discard"
    r"|ioutil\.Discard"
    r"|[A-Za-z_][A-Za-z_0-9.]*"
    r")\b",
    re.MULTILINE,
)
targets = [m.group(1) for m in discard_re.finditer(src) if m.group(1) != "nil"]
print("PASS" if targets else f"FAIL: targets={targets}")
PYEOF
)
    if [[ "$OUT" == "PASS"* ]]; then G3_PASS=true; fi
fi
echo "[gate] F2P_STDERR_DISCARD         pass=$G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 4 (F2P_DISCARD_CONCEPT_COVERED, weight 0.30):
# At least one of three known-good discard mechanisms is materially used in the
# file. Concept-coverage gate: pass if ≥1 of {io.Discard wired up,
# ioutil.Discard wired up, *os.File opened against /dev/null}. This is the
# "new pattern added" gate — closes the loophole where an agent might delete
# the nil lines (passing Gate 1) without actually replacing them with a sink.
# ──────────────────────────────────────────────────────────────────────────────
G4_PASS=false
if [ -f "$SRC" ]; then
    python3 - "$SRC" <<'PYEOF' && G4_PASS=true
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
# imports section (Go convention)
imports_re = re.compile(r'import\s*\(([^)]*)\)', re.DOTALL)
m = imports_re.search(s)
imports = m.group(1) if m else ""
has_io = bool(re.search(r'^\s*"io"\s*$', imports, re.MULTILINE))
has_ioutil = bool(re.search(r'^\s*"io/ioutil"\s*$', imports, re.MULTILINE))
has_os = bool(re.search(r'^\s*"os"\s*$', imports, re.MULTILINE))
# referenced in body
uses_io_discard = "io.Discard" in s
uses_ioutil_discard = "ioutil.Discard" in s
uses_devnull_open = ('"/dev/null"' in s or "'/dev/null'" in s) and \
                    ("os.OpenFile" in s or "os.Open" in s) and has_os
ok = (has_io and uses_io_discard) or \
     (has_ioutil and uses_ioutil_discard) or \
     uses_devnull_open
sys.exit(0 if ok else 1)
PYEOF
fi
echo "[gate] F2P_DISCARD_CONCEPT_COVERED pass=$G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# P2P_REGRESSION (informational only — never positive or negative reward).
# Per CLAUDE.md scoring rules, P2P_REGRESSION is logged for audit but does
# NOT zero the reward (`p2p_failed = false` always).
#
# These do not contribute to the score because the buggy baseline ALREADY
# builds and the existing tests ALREADY pass — they're not discriminative.
# Including them as F2P would inflate the buggy baseline score (degenerate
# ceiling, the original v0.4.3 issue with this task).
# ──────────────────────────────────────────────────────────────────────────────
P1_PASS=false
BUILD_LOG="$LOGS_DIR/build.log"
(cd "$REPO" && GOFLAGS="-mod=mod" go build ./cmd/entire/cli/telemetry/... > "$BUILD_LOG" 2>&1)
if [ "$?" -eq 0 ]; then P1_PASS=true; fi
echo "[gate] P2P_BUILD_OK (informational)  pass=$P1_PASS  (log: $BUILD_LOG)"

P2_PASS=false
TEST_LOG="$LOGS_DIR/test_run.log"
(cd "$REPO" && GOFLAGS="-mod=mod" go test -count=1 -timeout 60s ./cmd/entire/cli/telemetry/... > "$TEST_LOG" 2>&1)
if [ "$?" -eq 0 ]; then P2_PASS=true; fi
echo "[gate] P2P_TESTS_PASS (informational) pass=$P2_PASS  (log: $TEST_LOG)"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$P1_PASS" "$P2_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
f2p_verdicts = [s == "true" for s in sys.argv[2:6]]
p2p_verdicts = [s == "true" for s in sys.argv[6:8]]
f2p_ids = [
    "F2P_NIL_REMOVED",
    "F2P_STDOUT_DISCARD",
    "F2P_STDERR_DISCARD",
    "F2P_DISCARD_CONCEPT_COVERED",
]
p2p_ids = ["P2P_BUILD_OK", "P2P_TESTS_PASS"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(f2p_ids, f2p_verdicts)]
gates += [{"id": gid, "pass": v, "kind": "P2P_REGRESSION"} for gid, v in zip(p2p_ids, p2p_verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# F2P_NIL_REMOVED              0.20
# F2P_STDOUT_DISCARD           0.25
# F2P_STDERR_DISCARD           0.25
# F2P_DISCARD_CONCEPT_COVERED  0.30
# total                        1.00  → inner_share = 0.0 (legacy reward fully replaced)

existing="0.0"
if [ -f "$LOGS_DIR/base_reward.txt" ]; then
    existing=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")
fi

# P2P_REGRESSION: informational only — diagnostic/penalty only
p2p_failed=false

# F2P: at least one gate must pass for non-zero reward (or existing > 0)
f2p_any_pass=false
for v in "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS"; do
    if [ "$v" = "true" ]; then
        f2p_any_pass=true
        break
    fi
done

reward=$(python3 - "$existing" "$f2p_any_pass" "$p2p_failed" \
    "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" <<'PYEOF'
import sys
existing = float(sys.argv[1])
f2p_any_pass = sys.argv[2] == "true"
p2p_failed = sys.argv[3] == "true"
v = [s == "true" for s in sys.argv[4:8]]
WEIGHTS = {
    "F2P_NIL_REMOVED":             0.20,
    "F2P_STDOUT_DISCARD":          0.25,
    "F2P_STDERR_DISCARD":          0.25,
    "F2P_DISCARD_CONCEPT_COVERED": 0.30,
}
ids = list(WEIGHTS.keys())
verdicts = dict(zip(ids, v))
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
echo "  F2P_NIL_REMOVED              = $G1_PASS  (weight 0.20)"
echo "  F2P_STDOUT_DISCARD           = $G2_PASS  (weight 0.25)"
echo "  F2P_STDERR_DISCARD           = $G3_PASS  (weight 0.25)"
echo "  F2P_DISCARD_CONCEPT_COVERED  = $G4_PASS  (weight 0.30)"
echo "  [P2P] BUILD_OK               = $P1_PASS  (informational only)"
echo "  [P2P] TESTS_PASS             = $P2_PASS  (informational only)"
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
