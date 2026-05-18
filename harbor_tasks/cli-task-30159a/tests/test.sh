#!/usr/bin/env bash
# Verifier — cli-task-30159a (entireio/cli versioncheck.TestUpdateCommand fix).
#
# The original session asks the agent to make TestUpdateCommand independent of the
# local filesystem (i.e. inject the executable path resolver, replace the loose
# permissive map with a deterministic table-driven test, and tighten the path
# substring checks to avoid usernames matching `/mise/` or `/homebrew/`).
#
# This verifier scores via 6 behavioral + structural F2P gates (weights sum to 1.00).
# Reward formula is weighted-replace, naturally bounded to [0, 1]. P2P_REGRESSION
# gates are informational only and never zero the reward (per CLAUDE.md).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/workspace/cli
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

SRC=cmd/entire/cli/versioncheck/versioncheck.go
TST=cmd/entire/cli/versioncheck/versioncheck_test.go

# Sanity: source files must exist (P2P regression — informational only)
P2P_FILES_OK=true
[ -f "$SRC" ] || P2P_FILES_OK=false
[ -f "$TST" ] || P2P_FILES_OK=false

# ──────────────────────────────────────────────────────────────────────────────
# Gate 1 (F2P_TEST_DETERMINISTIC, weight 0.25):
#   `go test -run ^TestUpdateCommand$` passes AND exercises >= 4 deterministic
#   subtests (table-driven). The original test calls updateCommand() once and
#   accepts any of three outputs — that is filesystem-dependent and cannot reach
#   4 subtests. After the fix, ≥4 t.Run cases inject a fake executablePath.
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=false
G1_LOG=$(go test -count=1 -v -run '^TestUpdateCommand$' ./cmd/entire/cli/versioncheck/ 2>&1)
echo "$G1_LOG" > "$LOGS_DIR/g1_test.log"
# Check overall TestUpdateCommand passed
if echo "$G1_LOG" | grep -qE '^(ok|--- PASS: TestUpdateCommand[[:space:]]|PASS$)'; then
    # Count distinct subtests (lines like "--- PASS: TestUpdateCommand/<name>")
    SUBTEST_COUNT=$(echo "$G1_LOG" | grep -cE '^[[:space:]]*--- (PASS|FAIL): TestUpdateCommand/')
    if [ "${SUBTEST_COUNT:-0}" -ge 4 ]; then
        G1_PASS=true
    fi
fi
echo "[G1_TEST_DETERMINISTIC] subtests=${SUBTEST_COUNT:-0} pass=$G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 2 (F2P_EXEC_INDIRECTION, weight 0.20):
#   `versioncheck.go` exposes a package-level function-typed variable (so the
#   test can override it). Implementation-agnostic regex: any `var <name> ...
#   = os.Executable` line at file scope. We do NOT pin the variable name.
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=false
if [ -f "$SRC" ]; then
    if grep -qE '^var[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*(=|[[:space:]][A-Za-z_].*=)[[:space:]]*os\.Executable' "$SRC"; then
        G2_PASS=true
    fi
fi
echo "[G2_EXEC_INDIRECTION] pass=$G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 3 (F2P_NO_DIRECT_OS_EXECUTABLE_IN_UPDATECMD, weight 0.15):
#   `updateCommand` no longer calls `os.Executable()` directly. We extract the
#   updateCommand function body via a small Python pass and assert it does NOT
#   contain `os.Executable(`.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=false
if [ -f "$SRC" ]; then
    G3_RES=$(python3 - "$SRC" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Find updateCommand function body
m = re.search(r'func\s+updateCommand\s*\([^)]*\)\s*[A-Za-z_]*\s*\{', src)
if not m:
    print("FAIL: updateCommand not found")
    sys.exit(0)
i = m.end()
depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{':
        depth += 1
    elif src[i] == '}':
        depth -= 1
    i += 1
body = src[m.end():i-1]
if 'os.Executable(' in body:
    print("FAIL: os.Executable( still called inside updateCommand")
else:
    print("PASS")
PYEOF
)
    [[ "$G3_RES" == PASS* ]] && G3_PASS=true
fi
echo "[G3_NO_DIRECT_OS_EXEC] $G3_RES pass=$G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 4 (F2P_PATH_SPECIFICITY, weight 0.15):
#   The path-substring checks are tightened so that a *username* like
#   `/home/mise/...` or `/home/homebrew/...` does NOT match. We require ≥3 of
#   the following 4 specific tokens to appear somewhere in updateCommand's body
#   (concept coverage per SWE-bench Verified — alternative valid implementations
#   can use `strings.Contains` with any of these specific patterns).
#     1. "/Cellar/"               (homebrew install dir)
#     2. "/opt/homebrew/"         (Apple Silicon homebrew prefix)
#     3. "/linuxbrew/"            (Linuxbrew namespace)
#     4. "/mise/installs/"        (mise install subpath)
#   AND the loose `/homebrew/` substring (with no leading `/opt`) and the loose
#   `/mise/` (with no `/installs/`) MUST be gone — those are the false-positive
#   roots the user complained about.
# ──────────────────────────────────────────────────────────────────────────────
G4_PASS=false
if [ -f "$SRC" ]; then
    G4_RES=$(python3 - "$SRC" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+updateCommand\s*\([^)]*\)\s*[A-Za-z_]*\s*\{', src)
if not m:
    print("FAIL: updateCommand not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]

specific_tokens = ["/Cellar/", "/opt/homebrew/", "/linuxbrew/", "/mise/installs/"]
hits = sum(1 for t in specific_tokens if t in body)

# Loose patterns that must be gone:
# `"/homebrew/"` as a literal string (without `/opt` prefix immediately before)
loose_homebrew = bool(re.search(r'"/homebrew/"', body))
# `"/mise/"` as a literal string (exactly that, not /mise/installs/)
loose_mise = bool(re.search(r'"/mise/"', body))

ok = hits >= 3 and not loose_homebrew and not loose_mise
print(f"hits={hits} loose_homebrew={loose_homebrew} loose_mise={loose_mise} -> {'PASS' if ok else 'FAIL'}")
PYEOF
)
    [[ "$G4_RES" == *PASS ]] && G4_PASS=true
fi
echo "[G4_PATH_SPECIFICITY] $G4_RES pass=$G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 5 (F2P_TEST_OVERRIDES_EXECUTABLE, weight 0.15):
#   `versioncheck_test.go::TestUpdateCommand` injects a fake executable path
#   resolver (i.e. assigns to the package-level variable that mirrors
#   os.Executable). Implementation-agnostic check: the test body must
#     (a) reference a variable whose name appears in a `var <name> ... = os.Executable`
#         declaration in versioncheck.go AND assign to it inside the test, OR
#     (b) reference any of `executablePath` / `execPath` / similar override sites.
#   We detect this by extracting the variable name from src and looking for
#   `<name> =` inside the TestUpdateCommand body in the test file.
# ──────────────────────────────────────────────────────────────────────────────
G5_PASS=false
if [ -f "$SRC" ] && [ -f "$TST" ]; then
    G5_RES=$(python3 - "$SRC" "$TST" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
tst = open(sys.argv[2]).read()
mvar = re.search(r'^var\s+([A-Za-z_][A-Za-z0-9_]*)[^\n]*=\s*os\.Executable', src, re.MULTILINE)
if not mvar:
    print("FAIL: no override variable in source")
    sys.exit(0)
varname = mvar.group(1)
mfunc = re.search(r'func\s+TestUpdateCommand\s*\(', tst)
if not mfunc:
    print("FAIL: TestUpdateCommand not found")
    sys.exit(0)
i = tst.find('{', mfunc.end())
depth = 1; j = i + 1
while j < len(tst) and depth > 0:
    if tst[j] == '{': depth += 1
    elif tst[j] == '}': depth -= 1
    j += 1
body = tst[i+1:j-1]
# Test must assign to the variable (override) AND restore it
assigns = bool(re.search(rf'\b{re.escape(varname)}\s*=', body))
print(f"varname={varname} assigns={assigns} -> {'PASS' if assigns else 'FAIL'}")
PYEOF
)
    [[ "$G5_RES" == *PASS ]] && G5_PASS=true
fi
echo "[G5_TEST_OVERRIDES] $G5_RES pass=$G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 6 (F2P_TABLE_DRIVEN, weight 0.10):
#   TestUpdateCommand uses a table-driven pattern: a slice of structs (with
#   a `name` field and either a `want`/`expected` field) iterated via t.Run.
#   We require ≥3 distinct `name:` fields inside the TestUpdateCommand body
#   AND a `t.Run(` invocation. Implementation-agnostic — we don't pin field
#   names beyond `name`.
# ──────────────────────────────────────────────────────────────────────────────
G6_PASS=false
if [ -f "$TST" ]; then
    G6_RES=$(python3 - "$TST" <<'PYEOF'
import re, sys
tst = open(sys.argv[1]).read()
mfunc = re.search(r'func\s+TestUpdateCommand\s*\(', tst)
if not mfunc:
    print("FAIL: TestUpdateCommand not found"); sys.exit(0)
i = tst.find('{', mfunc.end())
depth = 1; j = i + 1
while j < len(tst) and depth > 0:
    if tst[j] == '{': depth += 1
    elif tst[j] == '}': depth -= 1
    j += 1
body = tst[i+1:j-1]
has_trun = 't.Run(' in body
n_names = len(re.findall(r'\bname\s*:\s*"', body))
ok = has_trun and n_names >= 3
print(f"t.Run={has_trun} n_names={n_names} -> {'PASS' if ok else 'FAIL'}")
PYEOF
)
    [[ "$G6_RES" == *PASS ]] && G6_PASS=true
fi
echo "[G6_TABLE_DRIVEN] $G6_RES pass=$G6_PASS"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" "$P2P_FILES_OK" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
verdicts = [s == "true" for s in sys.argv[2:8]]
p2p_ok = sys.argv[8] == "true"
ids = ["F2P_TEST_DETERMINISTIC", "F2P_EXEC_INDIRECTION", "F2P_NO_DIRECT_OS_EXEC",
       "F2P_PATH_SPECIFICITY", "F2P_TEST_OVERRIDES", "F2P_TABLE_DRIVEN"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(ids, verdicts)]
gates.append({"id": "P2P_SOURCE_FILES_EXIST", "pass": p2p_ok, "kind": "P2P_REGRESSION"})
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula ──────────────────────────────────────────
# Weights sum to 1.00 — the inner_share is 0 so any prior `existing` reward
# (none here; this is a fresh evaluator with no SWE-rebench fallback) does not
# contribute. P2P_REGRESSION is informational only.
reward=$(python3 <<PYEOF
weights = {
    'F2P_TEST_DETERMINISTIC':  0.25,
    'F2P_EXEC_INDIRECTION':    0.20,
    'F2P_NO_DIRECT_OS_EXEC':   0.15,
    'F2P_PATH_SPECIFICITY':    0.15,
    'F2P_TEST_OVERRIDES':      0.15,
    'F2P_TABLE_DRIVEN':        0.10,
}
verdicts = {
    'F2P_TEST_DETERMINISTIC':  '$G1_PASS' == 'true',
    'F2P_EXEC_INDIRECTION':    '$G2_PASS' == 'true',
    'F2P_NO_DIRECT_OS_EXEC':   '$G3_PASS' == 'true',
    'F2P_PATH_SPECIFICITY':    '$G4_PASS' == 'true',
    'F2P_TEST_OVERRIDES':      '$G5_PASS' == 'true',
    'F2P_TABLE_DRIVEN':        '$G6_PASS' == 'true',
}
existing = 0.0
p2p_failed = False  # P2P_REGRESSION informational only
f2p_any_pass = any(verdicts.values())

if not f2p_any_pass and existing <= 0:
    reward = 0.0
else:
    inner = max(0.0, 1.0 - sum(weights.values()))
    reward = existing * inner
    for gid, w in weights.items():
        if verdicts.get(gid):
            reward += float(w)

print(f"{max(0.0, min(1.0, reward)):.6f}")
PYEOF
)

echo "$reward" > "$REWARD_FILE"
echo "─────────────────────────────────────────────────"
echo "Gate verdicts:"
echo "  F2P_TEST_DETERMINISTIC = $G1_PASS"
echo "  F2P_EXEC_INDIRECTION   = $G2_PASS"
echo "  F2P_NO_DIRECT_OS_EXEC  = $G3_PASS"
echo "  F2P_PATH_SPECIFICITY   = $G4_PASS"
echo "  F2P_TEST_OVERRIDES     = $G5_PASS"
echo "  F2P_TABLE_DRIVEN       = $G6_PASS"
echo "Final reward: $reward"

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
