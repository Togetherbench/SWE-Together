#!/usr/bin/env bash
# Verifier — cli-task-cf32cb (entireio/cli "resume only from latest checkpoint
# on squash merges").
#
# The agent's task is to replace the multi-checkpoint branch in
# resumeFromCurrentBranch with a single-resume path that picks the newest
# checkpoint by CreatedAt, dropping the now-dead `resumeMultipleCheckpoints`
# and `deduplicateSessions` helpers, and updating the unit + integration tests
# to match. Canonical patch on entireio/cli @ commit 41d44c41 (parent
# 78bd0e3d).
#
# Verifier checks 6 behavioral / structural F2P gates (weight sum 1.00) plus an
# informational P2P_REGRESSION go-build gate. Reward formula is weighted-
# replace, naturally bounded to [0, 1]. P2P_REGRESSION never zeros the reward
# (per CLAUDE.md / scoring_traps.md).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/workspace/cli
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

RESUME=cmd/entire/cli/resume.go
RESUME_TEST=cmd/entire/cli/resume_test.go
INTEG_TEST=cmd/entire/cli/integration_test/resume_test.go

# Sanity: source files must exist (P2P regression — informational only)
P2P_FILES_OK=true
for f in "$RESUME" "$RESUME_TEST" "$INTEG_TEST"; do
    [ -f "$f" ] || P2P_FILES_OK=false
done

# ── Helper: strip Go comments before grep so a renamed/preserved comment can't
# satisfy a "removed" gate, and a leftover doc comment can't satisfy a "added"
# gate. Output goes to stdout. ────────────────────────────────────────────────
strip_go_comments() {
    python3 - "$1" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Block comments first (so // inside /* */ doesn't survive).
src = re.sub(r'/\*[\s\S]*?\*/', '', src)
# Line comments — be careful not to strip // inside string literals; for a
# best-effort verifier on Go source this naive approach is good enough (Go
# doesn't typically embed // inside strings on the same line as code we care
# about).
src = re.sub(r'//[^\n]*', '', src)
sys.stdout.write(src)
PYEOF
}

# Cache stripped versions of the three files for fast repeated grep.
STRIP_RESUME=$(strip_go_comments "$RESUME" 2>/dev/null || echo "")
STRIP_RESUME_TEST=$(strip_go_comments "$RESUME_TEST" 2>/dev/null || echo "")
STRIP_INTEG_TEST=$(strip_go_comments "$INTEG_TEST" 2>/dev/null || echo "")

# ──────────────────────────────────────────────────────────────────────────────
# F2P_DEAD_HELPERS_REMOVED (weight 0.20)
#
# resume.go no longer references the now-dead helpers `resumeMultipleCheckpoints`
# or `deduplicateSessions` (function bodies AND call sites both gone). Buggy
# baseline references each ≥2 times (declaration + caller); canonical = 0.
# Comments stripped first so a leftover doc comment can't satisfy this gate.
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=false
DEAD_RMC=$(echo "$STRIP_RESUME" | grep -c 'resumeMultipleCheckpoints' 2>/dev/null)
DEAD_DEDUP=$(echo "$STRIP_RESUME" | grep -c 'deduplicateSessions' 2>/dev/null)
DEAD_RMC=${DEAD_RMC:-0}
DEAD_DEDUP=${DEAD_DEDUP:-0}
if [ "$DEAD_RMC" -eq 0 ] && [ "$DEAD_DEDUP" -eq 0 ]; then
    G1_PASS=true
fi
echo "[gate] F2P_DEAD_HELPERS_REMOVED: resumeMultipleCheckpoints=$DEAD_RMC deduplicateSessions=$DEAD_DEDUP (need 0+0) → $G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_RESOLVE_LATEST_ADDED (weight 0.20)
#
# A new helper that picks the latest checkpoint by CreatedAt is defined and
# used. Implementation-agnostic: any `func` whose name contains the words
# "latest" + "checkpoint" (case-insensitive) and is referenced from
# resumeFromCurrentBranch. Canonical names it `resolveLatestCheckpoint` but
# the agent could pick `pickLatestCheckpoint` etc. We require ≥2 references
# (definition + at least one call site).
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=false
RESOLVE_HITS=$(echo "$STRIP_RESUME" | grep -cEi '[A-Za-z_]*(resolve|pick|select|find|get)[A-Za-z_]*latest[A-Za-z_]*checkpoint[A-Za-z_]*' 2>/dev/null)
RESOLVE_HITS=${RESOLVE_HITS:-0}
# Also accept the canonical exact name as a strong signal.
CANON_RESOLVE=$(echo "$STRIP_RESUME" | grep -c 'resolveLatestCheckpoint' 2>/dev/null)
CANON_RESOLVE=${CANON_RESOLVE:-0}
if [ "$RESOLVE_HITS" -ge 2 ] || [ "$CANON_RESOLVE" -ge 2 ]; then
    G2_PASS=true
fi
echo "[gate] F2P_RESOLVE_LATEST_ADDED: latest-checkpoint-helper hits=$RESOLVE_HITS canonical=$CANON_RESOLVE (need ≥2) → $G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_SKIP_INFO_MESSAGE (weight 0.20)
#
# The integration_test (and/or resume.go) carries a literal "older checkpoints
# skipped" — the user-visible info message specified in the plan and asserted
# by the rewritten integration test. Buggy baseline=0; canonical=2.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=false
SKIP_HITS_RESUME=$(echo "$STRIP_RESUME" | grep -c 'older checkpoints skipped' 2>/dev/null)
SKIP_HITS_INTEG=$(echo "$STRIP_INTEG_TEST" | grep -c 'older checkpoints skipped' 2>/dev/null)
SKIP_HITS_RESUME=${SKIP_HITS_RESUME:-0}
SKIP_HITS_INTEG=${SKIP_HITS_INTEG:-0}
SKIP_TOTAL=$(( SKIP_HITS_RESUME + SKIP_HITS_INTEG ))
if [ "$SKIP_TOTAL" -ge 2 ]; then
    G3_PASS=true
fi
echo "[gate] F2P_SKIP_INFO_MESSAGE: 'older checkpoints skipped' resume=$SKIP_HITS_RESUME integ=$SKIP_HITS_INTEG (need sum ≥2) → $G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_DEDUP_TEST_REMOVED (weight 0.15)
#
# resume_test.go no longer contains TestDeduplicateSessions (the spec says to
# remove the 5 dedup subtests since the function itself is gone). Buggy
# baseline=1 occurrence; canonical=0. Comments stripped so the function name
# in a removed-doc-comment doesn't count.
# ──────────────────────────────────────────────────────────────────────────────
G4_PASS=false
DEDUP_TEST_HITS=$(echo "$STRIP_RESUME_TEST" | grep -c 'TestDeduplicateSessions' 2>/dev/null)
DEDUP_TEST_HITS=${DEDUP_TEST_HITS:-0}
if [ "$DEDUP_TEST_HITS" -eq 0 ]; then
    G4_PASS=true
fi
echo "[gate] F2P_DEDUP_TEST_REMOVED: TestDeduplicateSessions hits=$DEDUP_TEST_HITS (need 0) → $G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_LATEST_CHECKPOINT_TEST (weight 0.15)
#
# resume_test.go gained a new test for the latest-checkpoint resolver. The plan
# names it TestResolveLatestCheckpoint, but accept any test function whose name
# matches "TestResolve.*Latest.*Checkpoint" or "Test.*Latest.*Checkpoint" — the
# behavioral signal is "a unit test exercises the latest-checkpoint
# resolution path". Buggy baseline=0; canonical=1.
# ──────────────────────────────────────────────────────────────────────────────
G5_PASS=false
LATEST_TEST_HITS=$(echo "$STRIP_RESUME_TEST" | grep -cE '^func[[:space:]]+Test[A-Za-z_]*[Ll]atest[A-Za-z_]*[Cc]heckpoint' 2>/dev/null)
LATEST_TEST_HITS=${LATEST_TEST_HITS:-0}
if [ "$LATEST_TEST_HITS" -ge 1 ]; then
    G5_PASS=true
fi
echo "[gate] F2P_LATEST_CHECKPOINT_TEST: TestX*Latest*Checkpoint funcs=$LATEST_TEST_HITS (need ≥1) → $G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_INTEG_ASSERT_FLIPPED (weight 0.10)
#
# integration_test/resume_test.go's TestResume_SquashMergeMultipleCheckpoints
# no longer asserts that BOTH session1.ID AND session2.ID appear (the plan
# flips this so session1 must NOT appear, session2 still must). Behavioral
# signal: the test now contains "should NOT" / "should not appear" near
# session1.ID, OR the literal "Restored 2 sessions" reference inside the
# squash-merge test is gone (it survives in OTHER tests). We use the count
# of "Restored 2 sessions" string-literals in the file as a proxy: buggy=2;
# canonical=1 (1 reference remains in unrelated test).
# ──────────────────────────────────────────────────────────────────────────────
G6_PASS=false
RESTORED2_HITS=$(echo "$STRIP_INTEG_TEST" | grep -c '"Restored 2 sessions"' 2>/dev/null)
RESTORED2_HITS=${RESTORED2_HITS:-0}
# Buggy: 2 occurrences. Canonical: 1. Pass if ≤1.
if [ "$RESTORED2_HITS" -le 1 ]; then
    G6_PASS=true
fi
echo "[gate] F2P_INTEG_ASSERT_FLIPPED: 'Restored 2 sessions' literals=$RESTORED2_HITS (need ≤1) → $G6_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# P2P_REGRESSION: GO_BUILD — informational only, never positive reward.
# Per CLAUDE.md scoring rules, P2P_REGRESSION is logged for audit but does
# NOT zero the reward. We still record the build outcome for diagnostic
# visibility.
# ──────────────────────────────────────────────────────────────────────────────
BUILD_LOG="$LOGS_DIR/go_build.log"
go build ./cmd/entire/... > "$BUILD_LOG" 2>&1
BUILD_RC=$?
if [ "$BUILD_RC" = "0" ]; then
    P1_PASS=true
else
    P1_PASS=false
    echo "[gate] go build failed; tail of $BUILD_LOG:"
    tail -20 "$BUILD_LOG"
fi
echo "[gate] P2P_GO_BUILD (informational): rc=$BUILD_RC → $P1_PASS"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" "$P1_PASS" "$P2P_FILES_OK" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
f2p_verdicts = [s == "true" for s in sys.argv[2:8]]
p2p_build = sys.argv[8] == "true"
p2p_files = sys.argv[9] == "true"
f2p_ids = [
    "F2P_DEAD_HELPERS_REMOVED",
    "F2P_RESOLVE_LATEST_ADDED",
    "F2P_SKIP_INFO_MESSAGE",
    "F2P_DEDUP_TEST_REMOVED",
    "F2P_LATEST_CHECKPOINT_TEST",
    "F2P_INTEG_ASSERT_FLIPPED",
]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(f2p_ids, f2p_verdicts)]
gates.append({"id": "P2P_GO_BUILD", "pass": p2p_build, "kind": "P2P_REGRESSION"})
gates.append({"id": "P2P_SOURCE_FILES_EXIST", "pass": p2p_files, "kind": "P2P_REGRESSION"})
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# Sum of F2P weights = 1.00 (full replacement; legacy reward fully subsumed).
# P2P_REGRESSION is informational only (scoring_traps.md).
existing="0.0"
if [ -f "$LOGS_DIR/base_reward.txt" ]; then
    existing=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")
fi

# P2P_REGRESSION: informational only — never zero reward
p2p_failed=false

# F2P: at least one gate must pass for non-zero reward (or existing > 0)
f2p_any_pass=false
for v in "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS"; do
    if [ "$v" = "true" ]; then
        f2p_any_pass=true
        break
    fi
done

reward=$(python3 - "$existing" "$f2p_any_pass" "$p2p_failed" \
    "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" <<'PYEOF'
import sys
existing = float(sys.argv[1])
f2p_any_pass = sys.argv[2] == "true"
p2p_failed = sys.argv[3] == "true"
v = [s == "true" for s in sys.argv[4:10]]
WEIGHTS = {
    "F2P_DEAD_HELPERS_REMOVED":   0.20,
    "F2P_RESOLVE_LATEST_ADDED":   0.20,
    "F2P_SKIP_INFO_MESSAGE":      0.20,
    "F2P_DEDUP_TEST_REMOVED":     0.15,
    "F2P_LATEST_CHECKPOINT_TEST": 0.15,
    "F2P_INTEG_ASSERT_FLIPPED":   0.10,
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
echo "  F2P_DEAD_HELPERS_REMOVED   = $G1_PASS  (weight 0.20)"
echo "  F2P_RESOLVE_LATEST_ADDED   = $G2_PASS  (weight 0.20)"
echo "  F2P_SKIP_INFO_MESSAGE      = $G3_PASS  (weight 0.20)"
echo "  F2P_DEDUP_TEST_REMOVED     = $G4_PASS  (weight 0.15)"
echo "  F2P_LATEST_CHECKPOINT_TEST = $G5_PASS  (weight 0.15)"
echo "  F2P_INTEG_ASSERT_FLIPPED   = $G6_PASS  (weight 0.10)"
echo "  [P2P] GO_BUILD             = $P1_PASS  (informational only)"
echo "  [P2P] SOURCE_FILES_EXIST   = $P2P_FILES_OK  (informational only)"
echo "Final reward: $reward"
cat "$REWARD_FILE"
