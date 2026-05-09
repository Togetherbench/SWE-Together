#!/usr/bin/env bash
# Verifier — cli-task-c4c7e9: Remove trail title (auto-)generation code from
# the entireio/cli `feat/trails` branch.
#
# The buggy state (reconstructed in environment/reconstruct_buggy.py) contains
# a stale `cmd/entire/cli/summarize/trail_title.go` file plus a corresponding
# `generateTrailTitleForTrail` helper, summarize import, and call site inside
# `cmd/entire/cli/strategy/manual_commit_hooks.go`.
#
# Behavioral gates evaluated against the patched repo (each writes a JSON
# verdict to /logs/verifier/gates.json):
#   * F2P_TRAIL_TITLE_FILE_GONE         — trail_title.go no longer exists
#   * F2P_SUMMARIZE_IMPORT_GONE         — summarize import dropped from hooks file
#   * F2P_GEN_FUNC_GONE                 — generateTrailTitleForTrail removed
#   * F2P_GENERATE_TITLE_FUNC_GONE      — public GenerateTrailTitle removed
#   * F2P_TRAIL_PACKAGE_PRESERVED       — `trail` package still imported (P2P-style anti-regression)
# Plus an informational P2P_GO_BUILD gate that runs `go build ./cmd/entire/...`
# but never zeroes the reward (per scoring_traps.md).
#
# Reward is computed via the canonical weighted-replace formula in [0, 1]
# (CLAUDE.md / scoring_traps.md). Sum of F2P weights = 1.00.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/workspace/repo
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

HOOKS_FILE="cmd/entire/cli/strategy/manual_commit_hooks.go"
TRAIL_TITLE_FILE="cmd/entire/cli/summarize/trail_title.go"

# Helper: strip Go line comments (`//`) and block comments (`/* ... */`) so
# gates check actual code, not commented-out leftovers. We deliberately do NOT
# collapse string literals — Go imports ARE quoted strings, and the gates need
# to see them. Only raw-string backtick blocks (`...`) get collapsed because
# they can contain example code or docstrings that mention the removed names.
strip_go() {
    local f="$1"
    if [ ! -f "$f" ]; then echo ""; return; fi
    python3 - "$f" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# remove block comments
src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)
# remove line comments
src = re.sub(r'//[^\n]*', '', src)
# collapse raw string literals (backticks) — these are usually multi-line
# templates or test fixtures that may mention the removed names harmlessly.
# Keep regular "..." strings intact: Go import paths live in those.
src = re.sub(r'`[^`]*`', '`STR`', src)
print(src)
PYEOF
}

HOOKS_SRC=$(strip_go "$HOOKS_FILE")

# ──────────────────────────────────────────────────────────────────────────────
# F2P_TRAIL_TITLE_FILE_GONE (weight 0.30)
#
# trail_title.go must no longer exist. The buggy state shipped this 99-line
# file; canonical patch deletes it entirely. Headline behavioral gate.
# ──────────────────────────────────────────────────────────────────────────────
if [ ! -f "$TRAIL_TITLE_FILE" ]; then
    G1_PASS=true
else
    # Tolerate a trivial stub (e.g. <= 5 non-blank lines) in case the agent
    # left an empty package declaration. Anything substantial fails the gate.
    NONBLANK=$(grep -cE '^[[:space:]]*[^[:space:]/]' "$TRAIL_TITLE_FILE" 2>/dev/null || echo 0)
    NONBLANK=${NONBLANK//[[:space:]]/}
    if [ -n "$NONBLANK" ] && [ "$NONBLANK" -le 3 ]; then
        G1_PASS=true
    else
        G1_PASS=false
    fi
fi
echo "[gate] F2P_TRAIL_TITLE_FILE_GONE: trail_title.go absent (or trivial stub) → $G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_SUMMARIZE_IMPORT_GONE (weight 0.20)
#
# manual_commit_hooks.go must no longer import the summarize package. Comments
# and string literals are stripped so a doc reference doesn't keep this gate
# failing. Buggy state has the import; canonical patch drops it.
# ──────────────────────────────────────────────────────────────────────────────
if [ -z "$HOOKS_SRC" ]; then
    G2_PASS=false
else
    if echo "$HOOKS_SRC" | grep -qE 'cmd/entire/cli/summarize'; then
        G2_PASS=false
    else
        G2_PASS=true
    fi
fi
echo "[gate] F2P_SUMMARIZE_IMPORT_GONE: summarize import absent in $HOOKS_FILE → $G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_GEN_FUNC_GONE (weight 0.25)
#
# `generateTrailTitleForTrail` (the private helper) must be gone — both the
# call site and the function definition. We check the comment-stripped source
# so a stale doc string doesn't keep this gate failing. Anti-stub: rejects any
# definition longer than a no-op (>3 statements).
# ──────────────────────────────────────────────────────────────────────────────
if [ -z "$HOOKS_SRC" ]; then
    G3_PASS=false
elif echo "$HOOKS_SRC" | grep -qE 'generateTrailTitleForTrail\s*\('; then
    G3_PASS=false
else
    G3_PASS=true
fi
echo "[gate] F2P_GEN_FUNC_GONE: generateTrailTitleForTrail removed from hooks file → $G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_GENERATE_TITLE_FUNC_GONE (weight 0.15)
#
# The public `GenerateTrailTitle` function (defined in trail_title.go in the
# buggy state) must not exist anywhere under cmd/. Implementation-agnostic:
# checks every .go file (production + test) for `func GenerateTrailTitle`.
# ──────────────────────────────────────────────────────────────────────────────
HITS=$(grep -rlE '^func +GenerateTrailTitle\b' --include='*.go' cmd/ 2>/dev/null | wc -l)
HITS=${HITS//[[:space:]]/}
if [ "$HITS" = "0" ]; then
    G4_PASS=true
else
    G4_PASS=false
fi
echo "[gate] F2P_GENERATE_TITLE_FUNC_GONE: GenerateTrailTitle defs found = $HITS (need 0) → $G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# F2P_TRAIL_PACKAGE_PRESERVED (weight 0.10)
#
# Anti-overfit / anti-regression: the hooks file STILL needs the `trail`
# package import (for `appendCheckpointToExistingTrail`). An overzealous agent
# that nuked the entire trail subsystem would fail this gate. Looks for the
# import path AND a usage of `trail.Store` — both should remain.
# ──────────────────────────────────────────────────────────────────────────────
if [ -z "$HOOKS_SRC" ]; then
    G5_PASS=false
elif echo "$HOOKS_SRC" | grep -qE 'cmd/entire/cli/trail' \
   && echo "$HOOKS_SRC" | grep -qE 'trail\.(Store|ID|Metadata)'; then
    G5_PASS=true
else
    G5_PASS=false
fi
echo "[gate] F2P_TRAIL_PACKAGE_PRESERVED: trail package still wired into hooks file → $G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# P2P_REGRESSION: GO_BUILD — informational only, never positive reward.
# Per CLAUDE.md scoring rules, P2P_REGRESSION is logged for audit but does
# NOT zero the reward (`p2p_failed = false` always).
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
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$P1_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
f2p_verdicts = [s == "true" for s in sys.argv[2:7]]
p2p_verdicts = [s == "true" for s in sys.argv[7:8]]
f2p_ids = [
    "F2P_TRAIL_TITLE_FILE_GONE",
    "F2P_SUMMARIZE_IMPORT_GONE",
    "F2P_GEN_FUNC_GONE",
    "F2P_GENERATE_TITLE_FUNC_GONE",
    "F2P_TRAIL_PACKAGE_PRESERVED",
]
p2p_ids = ["P2P_GO_BUILD"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(f2p_ids, f2p_verdicts)]
gates += [{"id": gid, "pass": v, "kind": "P2P_REGRESSION"} for gid, v in zip(p2p_ids, p2p_verdicts)]
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
for v in "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS"; do
    if [ "$v" = "true" ]; then
        f2p_any_pass=true
        break
    fi
done

reward=$(python3 - "$existing" "$f2p_any_pass" "$p2p_failed" \
    "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" <<'PYEOF'
import sys
existing = float(sys.argv[1])
f2p_any_pass = sys.argv[2] == "true"
p2p_failed = sys.argv[3] == "true"
v = [s == "true" for s in sys.argv[4:9]]
WEIGHTS = {
    "F2P_TRAIL_TITLE_FILE_GONE":     0.30,
    "F2P_SUMMARIZE_IMPORT_GONE":     0.20,
    "F2P_GEN_FUNC_GONE":             0.25,
    "F2P_GENERATE_TITLE_FUNC_GONE":  0.15,
    "F2P_TRAIL_PACKAGE_PRESERVED":   0.10,
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
echo "  F2P_TRAIL_TITLE_FILE_GONE     = $G1_PASS  (weight 0.30)"
echo "  F2P_SUMMARIZE_IMPORT_GONE     = $G2_PASS  (weight 0.20)"
echo "  F2P_GEN_FUNC_GONE             = $G3_PASS  (weight 0.25)"
echo "  F2P_GENERATE_TITLE_FUNC_GONE  = $G4_PASS  (weight 0.15)"
echo "  F2P_TRAIL_PACKAGE_PRESERVED   = $G5_PASS  (weight 0.10)"
echo "  [P2P] GO_BUILD                = $P1_PASS  (informational only)"
echo "Final reward: $reward"
cat "$REWARD_FILE"
