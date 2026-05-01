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
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_api_key_path_preserved": 0.2, "t1_f2p_no_jwt_only_handler_auth": 0.25, "t1_f2p_not_release_cfg_eliminated": 0.3, "t1_f2p_release_cfg_eliminated": 0.25}
P2P_GATING = ["p2p_file_present"]
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
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
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

# ---------- F2P Gate 1: cfg(not(feature="release")) attrs eliminated (0.30) ----------
# No-op base has many (>20). Correct fix has 0.
if [ "$NOT_REL" -eq 0 ]; then
    emit t1_f2p_not_release_cfg_eliminated true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.30}")
else
    emit t1_f2p_not_release_cfg_eliminated false "$NOT_REL cfg(not(release)) attrs remain"
fi

# ---------- F2P Gate 2: cfg(feature="release") attrs eliminated (0.25) ----------
if [ "$REL" -eq 0 ]; then
    emit t1_f2p_release_cfg_eliminated true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.25}")
else
    emit t1_f2p_release_cfg_eliminated false "$REL cfg(release) attrs remain"
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

if [ "$JWT_ONLY_HITS" -eq 0 ]; then
    emit t1_f2p_no_jwt_only_handler_auth true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.25}")
else
    emit t1_f2p_no_jwt_only_handler_auth false "$JWT_ONLY_HITS JWT-only handler-auth sites remain"
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

if [ "$AUTH_TYPE" -ge $((LOCK_ACTIONS - 2)) ] \
        && [ "$API_KEY_AUTH" -ge 20 ] \
        && [ "$JWT_ONLY_HITS" -eq 0 ] \
        && [ "$LOCK_ACTIONS" -ge 20 ]; then
    emit t1_f2p_api_key_path_preserved true ""
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + 0.20}")
else
    emit t1_f2p_api_key_path_preserved false "auth_type=$AUTH_TYPE api_key=$API_KEY_AUTH lock=$LOCK_ACTIONS jwt_only=$JWT_ONLY_HITS"
fi

write_reward "$REWARD"