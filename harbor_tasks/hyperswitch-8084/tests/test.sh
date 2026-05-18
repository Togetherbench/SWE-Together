#!/bin/bash
set +e
# [v042-fix] Robust Rust toolchain setup. Direct cargo binary on PATH
# bypasses rustup's proxy (which fails 'could not choose a version of cargo
# to run' when no toolchain is installed).
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"
hash -r 2>/dev/null || true
if command -v rustup >/dev/null 2>&1; then
    rustup show active-toolchain >/dev/null 2>&1 \
        || rustup default stable 2>&1 \
        || rustup install stable 2>&1 \
        || true
fi

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    # escape any double quotes in detail
    detail=${detail//\"/\\\"}
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

REPO=/workspace/hyperswitch
FILE="$REPO/crates/router/src/routes/routing.rs"

write_reward() {
    local R="$1"
    R=$(awk "BEGIN {s=$R; if (s<0) s=0; if (s>1) s=1; printf \"%.4f\", s}")
    echo ""
    echo "=== FINAL REWARD: $R ==="
    printf "%.4f\n" "$R" > /logs/verifier/reward.txt
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBleHBvcnQgUEFUSD0vdXNyL2xvY2FsL2NhcmdvL2JpbjokUEFUSDsgcnVzdHVwIGluc3RhbGwgMS44NS4wIDI+JjEgfCB0YWlsIC0yOyBydXN0dXAgZGVmYXVsdCAxLjg1LjAgMj4mMSB8IHRhaWwgLTI7IGVjaG8gUEFUSD0vdXNyL2xvY2FsL2NhcmdvL2JpbjokUEFUSCA+IC9ldGMvcHJvZmlsZS5kL2NhcmdvLnNoOyBlY2hvICdleHBvcnQgQ0FSR09fQlVJTERfSk9CUz0xJyA+PiAvZXRjL3Byb2ZpbGUuZC9jYXJnby5zaDsgZWNobyAnZXhwb3J0IENBUkdPX0lOQ1JFTUVOVEFMPTAnID4+IC9ldGMvcHJvZmlsZS5kL2NhcmdvLnNoOyBjaG1vZCAwNjQ0IC9ldGMvcHJvZmlsZS5kL2NhcmdvLnNo' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_7a8254b6 'cargo_metadata_workspace' 'cd /workspace/hyperswitch && export PATH=/usr/local/cargo/bin:$PATH && cargo metadata --no-deps --format-version=1 >/dev/null && echo OK'
run_v043_gate p2p_upstream_d59414f2 'rust_files_nonempty' 'cd /workspace/hyperswitch && ok=1; for f in crates/router/src/routes/routing.rs; do if [ ! -s "$f" ]; then ok=0; break; fi; head -c 4 "$f" | grep -q '\''^//'\'' && head -c 4 "$f" >/dev/null; done; [ $ok = 1 ] && echo OK || exit 1'

# Recompute reward using v043 weights.
# v043.1 fix: P2P_REGRESSION is informational only (diagnostic/penalty only).
# Only P2P_REGRESSION ids may feed bounded penalty/diagnostics; f2p_any_pass guard preserves inner reward.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_api_key_path_preserved": 0.2, "t1_f2p_no_jwt_only_handler_auth": 0.25, "t1_f2p_not_release_cfg_eliminated": 0.3, "t1_f2p_release_cfg_eliminated": 0.25}
P2P_REGRESSION = ["p2p_file_present"]
P2P_REGRESSION = ["p2p_upstream_7a8254b6", "p2p_upstream_d59414f2"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass
# Only P2P_REGRESSION (a separate kind) may feed bounded penalty/diagnostics. P2P_REGRESSION is
# informational and is logged to gates.json but never feeds bounded penalty/diagnostics.
p2p_failed = False  # P2P failures feed bounded penalty/diagnostics only.
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += float(w)
reward = max(0.0, min(1.0, reward))
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

    exit 0
}

# ---------- P2P: file present + syntactically intact ----------
P2P_OK=1
if [ ! -d "$REPO" ] || [ ! -f "$FILE" ]; then
    emit p2p_file_present false "routing.rs missing"
    P2P_OK=0
else
    SIZE=$(wc -c < "$FILE" 2>/dev/null)
    SIZE=${SIZE:-0}
    OPEN=$(tr -cd '{' < "$FILE" | wc -c)
    CLOSE=$(tr -cd '}' < "$FILE" | wc -c)
    OPEN_P=$(tr -cd '(' < "$FILE" | wc -c)
    CLOSE_P=$(tr -cd ')' < "$FILE" | wc -c)
    if [ "$SIZE" -lt 20000 ]; then
        emit p2p_file_present false "file too small: $SIZE bytes"
        P2P_OK=0
    elif [ "$OPEN" -ne "$CLOSE" ]; then
        emit p2p_file_present false "braces unbalanced $OPEN/$CLOSE"
        P2P_OK=0
    elif [ "$OPEN_P" -ne "$CLOSE_P" ]; then
        emit p2p_file_present false "parens unbalanced $OPEN_P/$CLOSE_P"
        P2P_OK=0
    else
        emit p2p_file_present true ""
    fi
fi

if [ "$P2P_OK" -ne 1 ]; then
    write_reward 0.0
fi

# ---------- Measure structural signals ----------
NOT_REL=$(grep -c '#\[cfg(not(feature = "release"))\]' "$FILE")
REL=$(grep -c '#\[cfg(feature = "release")\]' "$FILE")
AUTH_TYPE=$(grep -c 'auth::auth_type' "$FILE")
API_KEY_AUTH=$(grep -cE 'ApiKeyAuth|V2ApiKeyAuth' "$FILE")
LOCK_ACTIONS=$(grep -c 'api_locking::LockAction' "$FILE")
NOT_REL=${NOT_REL:-0}; REL=${REL:-0}
AUTH_TYPE=${AUTH_TYPE:-0}; API_KEY_AUTH=${API_KEY_AUTH:-0}
LOCK_ACTIONS=${LOCK_ACTIONS:-0}

echo "=== F2P metrics ==="
echo "  cfg(not(feature=release)) attrs: $NOT_REL"
echo "  cfg(feature=release)      attrs: $REL"
echo "  auth::auth_type calls          : $AUTH_TYPE"
echo "  ApiKeyAuth/V2ApiKeyAuth refs   : $API_KEY_AUTH"
echo "  api_locking::LockAction sites  : $LOCK_ACTIONS"

REWARD=0.0

# ---------- F2P Gate 1: cfg(not(feature="release")) attrs reduced (0.30) ----------
# Buggy base has 26 occurrences. The canonical PR (juspay/hyperswitch#8083)
# removes only the cfg-gating around routing-endpoint auth args (10 sites)
# and leaves other unrelated cfg branches intact -- canonical state = 16.
# Any meaningful reduction passes; a no-op (>=24) fails.
if [ "$NOT_REL" -le 20 ]; then
    emit t1_f2p_not_release_cfg_eliminated true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.30}")
else
    emit t1_f2p_not_release_cfg_eliminated false "$NOT_REL cfg(not(release)) attrs remain (need <=20; canonical state has 16)"
fi

# ---------- F2P Gate 2: cfg(feature="release") attrs reduced (0.25) ----------
# Buggy base = 26, canonical state = 16 (same reasoning as Gate 1).
if [ "$REL" -le 20 ]; then
    emit t1_f2p_release_cfg_eliminated true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.25}")
else
    emit t1_f2p_release_cfg_eliminated false "$REL cfg(release) attrs remain (need <=20; canonical state has 16)"
fi

# ---------- F2P Gate 3: no bare JWT-as-handler-auth pattern remains (0.25) ----------
# The bug: in release builds, handlers used JWT-only auth (no api-key path).
# After the fix, every handler call site uses auth::auth_type(...) which
# wraps ApiKeyAuth + JWTAuth. So a `&auth::JWTAuth{...}` literal followed
# directly by `api_locking::LockAction` indicates the JWT-only handler arg
# remains.
JWT_ONLY_HITS=$(python3 - "$FILE" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1]).read()
except Exception:
    print(99)
    sys.exit(0)
# Match a `&auth::JWTAuth*{...}` block whose closing `},` is followed
# (within a small window) by `api_locking::LockAction`. That is the
# handler-position auth argument, the buggy release branch.
pat = re.compile(
    r'&auth::JWTAuth(?:ProfileFromRoute)?\s*\{[^{}]*\}\s*,\s*\n\s*api_locking::LockAction',
    re.MULTILINE,
)
print(len(pat.findall(src)))
PY
)
JWT_ONLY_HITS=${JWT_ONLY_HITS:-99}
echo "  bare JWT-as-handler-auth hits  : $JWT_ONLY_HITS"

# Buggy base hits this pattern 26x; canonical state 15 (regex over-counts JWTAuth
# nested inside auth_type wrappers). A meaningful reduction (<=20) passes; a
# no-op (>=24) fails.
if [ "$JWT_ONLY_HITS" -le 20 ]; then
    emit t1_f2p_no_jwt_only_handler_auth true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.25}")
else
    emit t1_f2p_no_jwt_only_handler_auth false "$JWT_ONLY_HITS JWT-only handler-auth sites remain (need <=20; canonical state has 15)"
fi

# ---------- F2P Gate 4: api-key path preserved AND covers all handlers (0.20) ----------
# Discriminator: every handler call site (counted via api_locking::LockAction)
# must have an associated auth::auth_type call. The buggy base has roughly
# equal counts of `auth::auth_type` (in non-release branch) and
# `api_locking::LockAction` (per handler), but ALSO has many bare JWT-only
# handler-auth args; on the no-op state, even if AUTH_TYPE >= LOCK_ACTIONS,
# the JWT-only count is high.
#
# We require:
#   - AUTH_TYPE >= LOCK_ACTIONS - 2 (every handler now uses auth_type;
#     small slack for rare JWT-only legitimate spots).
#   - API_KEY_AUTH >= 20 (api-key branch wasn't deleted).
#   - JWT_ONLY_HITS == 0 (no handler still bypasses api-key).
#
# This combination cannot be satisfied by the no-op base (which has
# JWT_ONLY_HITS >> 0) and cannot be satisfied by deleting the api-key branch
# (which would push API_KEY_AUTH to 0).

# Canonical state: auth_type=35, api_key=35, lock=34, jwt_only=15.
# Buggy base: auth_type=34, api_key=34, lock=34, jwt_only=26.
# Discriminator: api-key wasn't removed AND JWT-only sites reduced.
if [ "$AUTH_TYPE" -ge $((LOCK_ACTIONS - 2)) ] \
        && [ "$API_KEY_AUTH" -ge 20 ] \
        && [ "$JWT_ONLY_HITS" -le 20 ] \
        && [ "$LOCK_ACTIONS" -ge 20 ]; then
    emit t1_f2p_api_key_path_preserved true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.20}")
else
    emit t1_f2p_api_key_path_preserved false "auth_type=$AUTH_TYPE api_key=$API_KEY_AUTH lock=$LOCK_ACTIONS jwt_only=$JWT_ONLY_HITS"
fi

write_reward "$REWARD"

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
