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

# P2P_REGRESSION: typecheck must pass
if typecheck_rc != 0:
    print(f"[eval] typecheck failed (rc={typecheck_rc}); zeroing reward")
    open(reward_path, "w").write("0.000000\n")
    sys.exit(0)

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
