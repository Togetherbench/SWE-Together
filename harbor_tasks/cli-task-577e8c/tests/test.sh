#!/usr/bin/env bash
# Verifier — cli-task-577e8c (entireio/cli — log warnings on session unmarshal failures).
#
# The original session opens with the user saying:
#   "if we catch any error unmarshaling session data we should, at least,
#    log a warning message with the content"
# After exploring the codebase, the canonical commit
# (4beb60c7f768fe53ca2abcff486a8d82fe19a6c6) adds `logging.Warn(...)` calls in
# four files where `json.Unmarshal` was silently swallowing session-related
# errors:
#   * cmd/entire/cli/agent/opencode/opencode.go      (ReadSession / ExtractModifiedFiles)
#   * cmd/entire/cli/strategy/common.go              (4 unmarshal sites)
#   * cmd/entire/cli/strategy/manual_commit_logs.go  (1 unmarshal site)
#   * cmd/entire/cli/strategy/session.go             (1 unmarshal site)
#
# The user's session ultimately *converged* on the opencode.go fix alone
# (see user_simulation_prompt.md Turn 3). We therefore weight opencode.go
# heavily (0.55 of 1.00) and reward the broader spread modestly (0.35),
# leaving 0.10 on `go build`.
#
# Five F2P gates (sum 1.00) + go-build informational floor:
#   F2P_OPENCODE_WARN_IN_READSESSION (0.30) — check_ast warn_call_present
#   F2P_OPENCODE_LOG_RICH            (0.25) — check_ast log_has_session_ref AND log_has_error AND error_branch_handles
#   F2P_LOGGING_IMPORT_SPREAD        (0.15) — ≥1 of 3 strategy files gains logging import
#   F2P_UNMARSHAL_WARN_SPREAD        (0.20) — ≥1 logging.{Info,Warn,Debug,Error}( call site in any of the 3 strategy files
#   F2P_GO_BUILD                     (0.10) — `go build` of touched packages succeeds (also gates other gates indirectly)
#
# Reward formula is weighted-replace, naturally bounded to [0, 1]. P2P_REGRESSION
# gates are informational only and never zero the reward (per CLAUDE.md scoring).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/app}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

# Locate check_ast.py — Harbor mounts the tests/ dir at /tests
CHECK_AST=""
for cand in /tests/check_ast.py "$TASK_DIR/tests/check_ast.py"; do
    if [ -f "$cand" ]; then CHECK_AST="$cand"; break; fi
done
if [ -z "$CHECK_AST" ]; then
    echo "ERROR: check_ast.py not found in /tests or $TASK_DIR/tests" >&2
    echo 0.0 > "$REWARD_FILE"
    exit 1
fi

OPENCODE_GO="cmd/entire/cli/agent/opencode/opencode.go"
STRATEGY_FILES=(
    "cmd/entire/cli/strategy/common.go"
    "cmd/entire/cli/strategy/manual_commit_logs.go"
    "cmd/entire/cli/strategy/session.go"
)

# ──────────────────────────────────────────────────────────────────────────────
# Gate 1 (F2P_OPENCODE_WARN_IN_READSESSION, weight 0.30)
#
# The headline anchor: the user's first message asked for a warning log on
# unmarshal/extract failure. check_ast.py extracts the *ReadSession* function
# body (not the whole file) and checks for a `logging.* (` or `slog.* (`
# call within it. Implementation-agnostic on the call name.
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=false
if [ -f "$OPENCODE_GO" ]; then
    if python3 "$CHECK_AST" "$OPENCODE_GO" --check=warn_call_present >/dev/null 2>&1; then
        G1_PASS=true
    fi
fi
echo "[G1_OPENCODE_WARN_IN_READSESSION] pass=$G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 2 (F2P_OPENCODE_LOG_RICH, weight 0.25)
#
# Conjunctive concept-coverage gate: the new warn call should include at least
#   * a session reference (sessionRef, SessionRef, sessionID, "...session..."), AND
#   * an error reference (err.Error(), Error(...), "error" key), AND
#   * the error branch must contain ≥1 meaningful statement beyond the
#     `modifiedFiles = nil` fallback.
# All three sub-checks live in check_ast.py and are scoped to ReadSession.
# This avoids rewarding a bare `logging.Warn(ctx, "oops")` with no detail.
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=false
if [ -f "$OPENCODE_GO" ]; then
    HAS_SREF=false; HAS_ERR=false; HAS_HANDLE=false
    python3 "$CHECK_AST" "$OPENCODE_GO" --check=log_has_session_ref >/dev/null 2>&1 && HAS_SREF=true
    python3 "$CHECK_AST" "$OPENCODE_GO" --check=log_has_error       >/dev/null 2>&1 && HAS_ERR=true
    python3 "$CHECK_AST" "$OPENCODE_GO" --check=error_branch_handles >/dev/null 2>&1 && HAS_HANDLE=true
    if [ "$HAS_SREF" = "true" ] && [ "$HAS_ERR" = "true" ] && [ "$HAS_HANDLE" = "true" ]; then
        G2_PASS=true
    fi
    echo "[G2_OPENCODE_LOG_RICH] session_ref=$HAS_SREF has_err=$HAS_ERR branch_handles=$HAS_HANDLE pass=$G2_PASS"
else
    echo "[G2_OPENCODE_LOG_RICH] $OPENCODE_GO missing → pass=false"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Gate 3 (F2P_LOGGING_IMPORT_SPREAD, weight 0.15)
#
# ≥1 of the 3 strategy files (common.go, manual_commit_logs.go, session.go)
# gains a logging package import. Threshold of 1 admits the user's converged
# opencode-only state (which would still get 0 here) without overweighting
# the canonical-commit's broader spread. The canonical patches all 3 files
# so it sails through.
# ──────────────────────────────────────────────────────────────────────────────
LOGGING_IMPORT_COUNT=0
for f in "${STRATEGY_FILES[@]}"; do
    if [ -f "$f" ] && grep -qE '"github\.com/entireio/cli/cmd/entire/cli/logging"' "$f"; then
        LOGGING_IMPORT_COUNT=$((LOGGING_IMPORT_COUNT + 1))
    fi
done
if [ "$LOGGING_IMPORT_COUNT" -ge 1 ]; then G3_PASS=true; else G3_PASS=false; fi
echo "[G3_LOGGING_IMPORT_SPREAD] $LOGGING_IMPORT_COUNT/3 strategy files import logging (need ≥1) → $G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 4 (F2P_UNMARSHAL_WARN_SPREAD, weight 0.20)
#
# ≥1 logging.{Info,Warn,Debug,Error}( call across the 3 strategy files.
# Buggy baseline is 0; canonical adds 6 (4 in common.go, 1 in manual_commit_logs.go,
# 1 in session.go). Threshold of 1 is intentionally generous — any partial
# spread is rewarded, but the user's opencode-only state still scores 0 here.
# ──────────────────────────────────────────────────────────────────────────────
STRATEGY_LOG_TOTAL=0
for f in "${STRATEGY_FILES[@]}"; do
    if [ -f "$f" ]; then
        n=$(grep -cE 'logging\.(Info|Warn|Debug|Error)\(' "$f" 2>/dev/null)
        n=${n//[[:space:]]/}
        STRATEGY_LOG_TOTAL=$(( STRATEGY_LOG_TOTAL + ${n:-0} ))
    fi
done
if [ "$STRATEGY_LOG_TOTAL" -ge 1 ]; then G4_PASS=true; else G4_PASS=false; fi
echo "[G4_UNMARSHAL_WARN_SPREAD] $STRATEGY_LOG_TOTAL logging.* calls across strategy/{common,manual_commit_logs,session}.go (need ≥1) → $G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 5 (F2P_GO_BUILD, weight 0.10)
#
# Touched packages still build cleanly. This catches missing imports
# (e.g. forgetting `"context"` after adding `context.Background()`) and
# typos in the new logging calls. Behavioral, not structural.
# ──────────────────────────────────────────────────────────────────────────────
BUILD_LOG="$LOGS_DIR/go_build.log"
go build ./cmd/entire/cli/agent/opencode/... ./cmd/entire/cli/strategy/... > "$BUILD_LOG" 2>&1
BUILD_RC=$?
if [ "$BUILD_RC" = "0" ]; then G5_PASS=true; else G5_PASS=false; fi
if [ "$G5_PASS" = "false" ]; then
    echo "[gate] go build failed; tail of $BUILD_LOG:"
    tail -30 "$BUILD_LOG"
fi
echo "[G5_GO_BUILD] rc=$BUILD_RC → $G5_PASS"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
verdicts = [s == "true" for s in sys.argv[2:7]]
ids = [
    "F2P_OPENCODE_WARN_IN_READSESSION",
    "F2P_OPENCODE_LOG_RICH",
    "F2P_LOGGING_IMPORT_SPREAD",
    "F2P_UNMARSHAL_WARN_SPREAD",
    "F2P_GO_BUILD",
]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(ids, verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# Sum of F2P weights = 1.00 → inner_share = 0.0 (legacy reward fully subsumed).
# P2P_REGRESSION is informational only (not used here; documented for parity).
existing="0.0"
if [ -f "$LOGS_DIR/base_reward.txt" ]; then
    existing=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")
fi

# P2P_REGRESSION: hard-coded false per CLAUDE.md (informational only).
p2p_failed=false

# F2P: at least one gate must pass for non-zero reward (or existing > 0).
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
    "F2P_OPENCODE_WARN_IN_READSESSION": 0.30,
    "F2P_OPENCODE_LOG_RICH":            0.25,
    "F2P_LOGGING_IMPORT_SPREAD":        0.15,
    "F2P_UNMARSHAL_WARN_SPREAD":        0.20,
    "F2P_GO_BUILD":                     0.10,
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
echo "  F2P_OPENCODE_WARN_IN_READSESSION = $G1_PASS  (weight 0.30)"
echo "  F2P_OPENCODE_LOG_RICH            = $G2_PASS  (weight 0.25)"
echo "  F2P_LOGGING_IMPORT_SPREAD        = $G3_PASS  (weight 0.15)"
echo "  F2P_UNMARSHAL_WARN_SPREAD        = $G4_PASS  (weight 0.20)"
echo "  F2P_GO_BUILD                     = $G5_PASS  (weight 0.10)"
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
