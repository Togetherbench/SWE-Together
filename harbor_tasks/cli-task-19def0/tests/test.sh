#!/usr/bin/env bash
# Source-grep verifier for cli-task-19def0 (Clean stale session files, entireio/cli #438).
#
# Why source-grep instead of `go test`: the original verifier injected gold tests
# into the buggy state via Dockerfile COPY (so agents saw exact test signatures).
# That injection broke E2B template aliases — every Dockerfile change invalidates
# the content-addressed image hash, and the rebuild loop blocked all replays.
#
# This verifier inspects the agent's source changes for the canonical fix's
# identifying landmarks instead of running named tests. Implementation-tolerant:
# multiple valid framings of the same fix score, but the buggy state cannot.
#
# Source of truth: canonical patch at
# data-pipeline/artifacts_cli/canonical_patches/19def01c-b939-40ef-b431-47aa7121df4c.json
#
# Discrimination check (counts in buggy state at commit 7f6c5bd3):
#   IsStale                     : 0 in state.go
#   StaleSessionThreshold       : 0 in state.go
#   store.Load(...) inside LoadSessionState: 0 (buggy does its own json.Unmarshal)
#   json.Unmarshal in LoadSessionState : 1 (buggy) → 0 (fix delegates)
# All gates target patterns that are 0-occurring in the buggy file.
set +e

export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/workspace/repo}"
STATE_GO="$REPO/cmd/entire/cli/session/state.go"
STRATEGY_GO="$REPO/cmd/entire/cli/strategy/session_state.go"
REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"

mkdir -p /logs/verifier
rm -f "$GATES_FILE"
echo "0.0" > "$REWARD_FILE"
: > "$GATES_FILE"

emit_gate() {
    local gid="$1" verdict="$2"
    printf '{"id":"%s","verdict":"%s"}\n' "$gid" "$verdict" >> "$GATES_FILE"
}

# Sanity: source files must exist
if [ ! -f "$STATE_GO" ]; then
    echo "ERROR: $STATE_GO not found" >&2
    exit 0
fi
if [ ! -f "$STRATEGY_GO" ]; then
    echo "ERROR: $STRATEGY_GO not found" >&2
    exit 0
fi

# ── G1 (0.25): IsStale method defined on *State ─────────────────────────────
# Canonical fix introduces `func (s *State) IsStale() bool`. Buggy: 0 hits.
# Accept both pointer and value receivers, and any whitespace.
g1=0
if grep -qE 'func[[:space:]]+\([[:space:]]*[a-zA-Z_]+[[:space:]]+\*?State[[:space:]]*\)[[:space:]]+IsStale\b' "$STATE_GO"; then
    g1=1
fi
if [ "$g1" = "1" ]; then emit_gate "g1_isstale_method" "pass"; else emit_gate "g1_isstale_method" "fail"; fi

# ── G2 (0.20): StateStore.Load deletes/skips stale sessions ─────────────────
# The Load method body must reference IsStale (or equivalent stale check) AND
# either Clear/os.Remove (delete the file) or return nil for the stale branch.
# Extract Load function body via awk and grep within it.
g2=0
load_body=$(awk '
    /func[[:space:]]+\([[:space:]]*[a-zA-Z_]+[[:space:]]+\*StateStore[[:space:]]*\)[[:space:]]+Load[[:space:]]*\(/ { in_fn=1; depth=0 }
    in_fn {
        print
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            else if (c == "}") { depth--; if (depth == 0) { in_fn=0; exit } }
        }
    }
' "$STATE_GO")
if printf '%s' "$load_body" | grep -qE '\bIsStale\b|\bStaleSessionThreshold\b|time\.Since.*LastInteractionTime'; then
    if printf '%s' "$load_body" | grep -qE '\bClear\b|os\.Remove|return[[:space:]]+nil,[[:space:]]*nil'; then
        g2=1
    fi
fi
if [ "$g2" = "1" ]; then emit_gate "g2_load_stale_check" "pass"; else emit_gate "g2_load_stale_check" "fail"; fi

# ── G3 (0.15): StaleSessionThreshold or equivalent threshold constant ───────
# Canonical: `StaleSessionThreshold = 7 * 24 * time.Hour`. Accept any
# constant/var named *Stale*Threshold* or a literal duration of 7*24*time.Hour
# / 14*24*time.Hour / time.Hour*24*7 etc. inside state.go.
g3=0
if grep -qE 'StaleSessionThreshold|staleSessionThreshold|Stale[A-Za-z]*Threshold' "$STATE_GO"; then
    g3=1
elif grep -qE '7[[:space:]]*\*[[:space:]]*24[[:space:]]*\*[[:space:]]*time\.Hour|14[[:space:]]*\*[[:space:]]*24[[:space:]]*\*[[:space:]]*time\.Hour|24[[:space:]]*\*[[:space:]]*time\.Hour[[:space:]]*\*[[:space:]]*7' "$STATE_GO"; then
    g3=1
fi
if [ "$g3" = "1" ]; then emit_gate "g3_stale_threshold_const" "pass"; else emit_gate "g3_stale_threshold_const" "fail"; fi

# ── G4 (0.20): strategy.LoadSessionState delegates to StateStore.Load ───────
# Canonical fix replaces the inline json.Unmarshal in LoadSessionState with a
# call to session.NewStateStore() + store.Load(ctx, sessionID). The buggy
# function reads the file + json.Unmarshal directly. Accept either:
#   (a) LoadSessionState body contains store.Load(   AND no json.Unmarshal, OR
#   (b) LoadSessionState body contains IsStale check inline (alt-fix that
#       puts the stale check in strategy package without delegating).
g4=0
load_session_body=$(awk '
    /func[[:space:]]+LoadSessionState[[:space:]]*\(/ { in_fn=1; depth=0 }
    in_fn {
        print
        for (i=1; i<=length($0); i++) {
            c = substr($0, i, 1)
            if (c == "{") depth++
            else if (c == "}") { depth--; if (depth == 0) { in_fn=0; exit } }
        }
    }
' "$STRATEGY_GO")
if printf '%s' "$load_session_body" | grep -qE 'store\.Load\s*\(|\.Load\(context\.|NewStateStore'; then
    if ! printf '%s' "$load_session_body" | grep -qE 'json\.Unmarshal'; then
        g4=1
    fi
fi
# Alt-fix: stale check inlined in strategy package
if [ "$g4" = "0" ]; then
    if printf '%s' "$load_session_body" | grep -qE '\bIsStale\b|StaleSessionThreshold|time\.Since.*LastInteractionTime'; then
        if printf '%s' "$load_session_body" | grep -qE '\bos\.Remove|return[[:space:]]+nil,[[:space:]]*nil'; then
            g4=1
        fi
    fi
fi
if [ "$g4" = "1" ]; then emit_gate "g4_strategy_delegates" "pass"; else emit_gate "g4_strategy_delegates" "fail"; fi

# ── G5 (0.10): build still compiles ─────────────────────────────────────────
# Catches agents who write nonsense that breaks the package. Build the two
# affected packages; on failure, this gate alone is denied — the source-grep
# gates above can still pass partial credit if the regex matches.
g5=0
cd "$REPO" || true
if go build ./cmd/entire/cli/session/... ./cmd/entire/cli/strategy/... > /tmp/build.log 2>&1; then
    g5=1
fi
if [ "$g5" = "1" ]; then emit_gate "g5_build_passes" "pass"; else emit_gate "g5_build_passes" "fail"; fi

# ── G6 (0.10): existing session/strategy unit tests still pass ──────────────
# Pass-to-pass safety net that doesn't depend on the agent writing new tests.
# Run only the directly-touched packages with a 90s timeout.
g6=0
test_log=$(go test ./cmd/entire/cli/session/ ./cmd/entire/cli/strategy/ -count=1 -timeout 90s -run '^Test[^_]' 2>&1)
test_rc=$?
if [ "$test_rc" = "0" ]; then
    g6=1
fi
if [ "$g6" = "1" ]; then emit_gate "g6_existing_tests_pass" "pass"; else emit_gate "g6_existing_tests_pass" "fail"; fi

# ── Compute reward (weighted-replace, never additive) ───────────────────────
python3 - <<'PYEOF'
import json

with open("/logs/verifier/gates.json") as f:
    verdicts = {}
    for line in f:
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        verdicts[d["id"]] = d["verdict"]

weights = {
    "g1_isstale_method":       0.25,
    "g2_load_stale_check":     0.20,
    "g3_stale_threshold_const":0.15,
    "g4_strategy_delegates":   0.20,
    "g5_build_passes":         0.10,
    "g6_existing_tests_pass":  0.10,
}
# Σ = 1.00 → inner_weight = 0, reward = sum(passed weights)

# P2P_REGRESSION: none here. Never zero reward on informational gates.
p2p_failed = False
existing = 0.0

f2p_any_pass = any(verdicts.get(g) == "pass" for g in weights)

if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(weights.values()))
    reward = existing * inner_weight
    for gid, w in weights.items():
        if verdicts.get(gid) == "pass":
            reward += float(w)

reward = max(0.0, min(1.0, reward))
with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{reward:.4f}\n")
passed = sum(1 for g in weights if verdicts.get(g) == "pass")
print(f"[eval] reward={reward:.4f}  gates_passed={passed}/{len(weights)}")
PYEOF

cat "$REWARD_FILE"
