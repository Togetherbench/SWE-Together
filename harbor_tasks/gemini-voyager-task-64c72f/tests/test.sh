#!/usr/bin/env bash
# Custom verifier for gemini-voyager-task-64c72f.
#
# Background: this task scaffolded with an AST-based verifier (verify.ts) that
# inspects manager.ts for the dot-reuse fix. The standard SWE-rebench vitest
# runner produces 0 here because the repo has zero *.test.ts files at this
# commit and the gold solution doesn't add any (test_files: [] in
# install_config.json). Instead we run the project's typescript verify.ts
# directly via `bun run` and convert its per-gate verdicts into a weighted
# F2P score matching test_manifest.yaml.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
EVAL_DIR="${EVAL_DIR:-/tests}"
REPO_DIR="/app"
mkdir -p "$LOGS_DIR"

LOG="$LOGS_DIR/test_run.log"
: > "$LOG"

cd "$REPO_DIR" || { echo "ERROR: cd $REPO_DIR" >&2; echo 0.0 > "$LOGS_DIR/reward.txt"; exit 1; }

# Locate verify.ts (mounted by Harbor as part of tests/ directory)
VERIFY_TS=""
for cand in "$EVAL_DIR/verify.ts" "$TASK_DIR/tests/verify.ts"; do
    if [ -f "$cand" ]; then
        VERIFY_TS="$cand"
        break
    fi
done
if [ -z "$VERIFY_TS" ]; then
    echo "ERROR: cannot locate verify.ts" | tee -a "$LOG" >&2
    echo 0.0 > "$LOGS_DIR/reward.txt"
    exit 1
fi

# Stage verify.ts inside the repo so it can resolve the project's `typescript` dep
cp "$VERIFY_TS" /tmp/verify.ts
echo "[eval] running AST verifier (bun run /tmp/verify.ts) from $REPO_DIR" | tee -a "$LOG"
bun run /tmp/verify.ts > "$LOGS_DIR/verify.out" 2> "$LOGS_DIR/verify.err"
VERIFY_RC=$?
cat "$LOGS_DIR/verify.out" "$LOGS_DIR/verify.err" >> "$LOG" 2>/dev/null

# Run the existing test suite gate (typecheck must pass; lint informational)
echo "[eval] running typecheck (P2P regression gate)" | tee -a "$LOG"
bun run typecheck >> "$LOG" 2>&1
TYPECHECK_RC=$?

python3 - "$LOGS_DIR/verify.out" "$LOGS_DIR/reward.txt" "$VERIFY_RC" "$TYPECHECK_RC" <<'PYEOF'
import json, sys, re

verify_out_path, reward_path, verify_rc, typecheck_rc = sys.argv[1:5]
verify_rc = int(verify_rc); typecheck_rc = int(typecheck_rc)

# Weights mirror test_manifest.yaml F2P gates (sum = 0.75; existing_tests_pass
# weight 0.15 is folded into the inner-share floor since there are no vitest
# tests to run — the AST gates carry the entire signal).
WEIGHTS = {
    "dot_reuse_map":                  0.20,   # was 0.15 + share of existing_tests
    "orphan_cleanup":                 0.15,   # was 0.10
    "no_blanket_removal_in_recalc":   0.20,   # was 0.15 + share
    "range_reset_preserves":          0.15,   # was 0.12
    "aria_label_update":              0.10,   # was 0.08
}
# Total = 0.80; remaining 0.20 is unallocated inner-share that stays 0
# because there is no legacy reward source.

verdicts = {}
try:
    raw = open(verify_out_path).read()
except FileNotFoundError:
    raw = ""

# verify.ts emits one JSON object per line: {"id": "...", "passed": true/false}
for line in raw.splitlines():
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
        gid = obj.get("id")
        if gid:
            verdicts[gid] = bool(obj.get("passed"))
    except json.JSONDecodeError:
        continue

# If verify.ts crashed (e.g., missing manager.ts), all gates fail
if verify_rc != 0 and not verdicts:
    print(f"[eval] verify.ts exited {verify_rc} with no verdicts; scoring 0")
    open(reward_path, "w").write("0.000000\n")
    sys.exit(0)

# P2P regression: typecheck (round-5 fix #139) — was previously treated as
# a hard zero. Per CLAUDE.md, pass-to-pass regression gates should be
# informational only (gating belongs to the dedicated pass-to-pass-gating
# kind). Demoted to a warning;
# typecheck routinely OOMs (rc=137) inside the E2B sandbox on the gemini
# repo (large TS surface), which would silently zero ALL canonical runs.
if typecheck_rc != 0:
    print(f"[eval] typecheck warning (rc={typecheck_rc}); informational, not zeroing reward")

# aria_label_update fires whenever setAttribute('aria-label', …) appears anywhere
# in updateVirtualRangeAndRender — but the buggy state also calls it (on new dot
# creation, line ~1232 in manager.ts). The gate is only meaningful evidence of
# the reuse refactor when paired with at least one structural reuse signal.
# Without this guard buggy state scores 0.10 (single false-positive gate).
if verdicts.get("aria_label_update") and not (
    verdicts.get("dot_reuse_map")
    or verdicts.get("orphan_cleanup")
    or verdicts.get("no_blanket_removal_in_recalc")
):
    print("[eval] aria_label_update suppressed (no reuse refactor evidence)")
    verdicts["aria_label_update"] = False

reward = 0.0
passed_gates = []
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += w
        passed_gates.append(gid)

reward = max(0.0, min(1.0, reward))
open(reward_path, "w").write(f"{reward:.6f}\n")

print(f"[eval] verdicts: {verdicts}")
print(f"[eval] passed: {passed_gates}")
print(f"[eval] reward={reward:.4f}")
PYEOF

cat "$LOGS_DIR/reward.txt"

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
