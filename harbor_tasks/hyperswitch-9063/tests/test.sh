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


REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

# Ensure node is available BEFORE the inner-bash F2P 1 block (which depends on
# it for behavioral locale.js testing). Without this, F2P 1 silently scores 0
# and pulls the total below 0.5 even when the canonical fix is applied.
if ! command -v node >/dev/null 2>&1; then
    (apt-get install -y nodejs 2>/dev/null || sudo apt-get install -y nodejs 2>/dev/null) >/dev/null 2>&1 || true
fi

REPO_DIR=""
for candidate in "/workspace/hyperswitch" "/workspace/repos/hyperswitch_pool_9" \
                 "/workspace/hyperswitch_pool_9" "./repos/hyperswitch_pool_9"; do
    if [ -d "$candidate/.git" ]; then
        REPO_DIR="$candidate"
        break
    fi
done
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(find /workspace -maxdepth 4 -name ".git" -type d 2>/dev/null | head -1 | xargs -r dirname)
fi

REWARD=0
write_reward() {
    echo "$REWARD" > "$REWARD_FILE"
}

if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR/.git" ]; then
    echo "FAIL: repo not found"
    write_reward
    exit 0
fi

cd "$REPO_DIR" || { write_reward; exit 0; }
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null

LOCALE_JS="$REPO_DIR/crates/router/src/core/payment_link/locale.js"
TRANSFORMERS="$REPO_DIR/crates/router/src/types/transformers.rs"
UTILS="$REPO_DIR/crates/router/src/utils.rs"
CONTEXT_RS="$REPO_DIR/crates/router/src/services/api/generic_link_response/context.rs"
MIDDLEWARE="$REPO_DIR/crates/router/src/middleware.rs"

# P2P gate: locale.js must exist
if [ ! -f "$LOCALE_JS" ]; then
    echo "GATE FAIL: locale.js missing"
    write_reward
    exit 0
fi

# Detect node
NODE_BIN=""
export PATH="/usr/local/bin:/usr/bin:$PATH"
for n in node nodejs; do
    if command -v "$n" >/dev/null 2>&1; then NODE_BIN="$n"; break; fi
done

add() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN { printf "%.4f", a + b }')
}

emit_gate() {
    local id="$1" passed="$2" detail="$3"
    detail="${detail//\"/\\\"}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> /logs/verifier/gates.json
}

###############################################################################
# F2P 1 (0.45): Behavioral test of locale.js getLanguage().
# On buggy base: getLanguage('zh_hant') returns 'zh' (because key uses underscore
# but split is on '-' so country=null), or returns 'zh_null', etc.
# On fix: getLanguage('zh_hant') returns 'zh-hant' (or at minimum, dictionary
# keys are hyphenated and underscores are normalized).
###############################################################################
echo "=== F2P 1: locale.js behavioral (0.27) ==="
F2P1=0
if [ -n "$NODE_BIN" ]; then
    TMPJS=$(mktemp /tmp/locale_run_XXXXXX.js)
    cat > "$TMPJS" <<'EOF'
const fs = require('fs');
const path = process.argv[2];
const src = fs.readFileSync(path, 'utf8');

const wrapper = `
${src}
;module.exports = {
  getLanguage: typeof getLanguage === 'function' ? getLanguage : null,
  dict: (typeof locales !== 'undefined') ? locales
       : (typeof translations !== 'undefined') ? translations
       : (typeof locale !== 'undefined') ? locale
       : (typeof localeStrings !== 'undefined') ? localeStrings
       : (typeof localeStr !== 'undefined') ? localeStr
       : null
};
`;
const Module = require('module');
const m = new Module('lut');
try {
  m._compile(wrapper, 'lut.js');
} catch (e) {
  console.log('COMPILE_ERR ' + e.message);
  process.exit(3);
}
const exp = m.exports;
if (typeof exp.getLanguage !== 'function') {
  console.log('NO_GETLANGUAGE');
  process.exit(2);
}

// F2P cases: these FAIL on buggy base (which uses underscore keys + split('-'))
// and PASS on fix.
// On buggy base:
//   getLanguage('zh_hant') -> split('-') yields ['zh_hant'], language='zh_hant',
//     key='zh_hant_null', default returns 'zh_hant' (NOT a valid dict key).
//   getLanguage('zh-hant') -> language='zh', country='hant', key='zh_hant',
//     no case matches, returns 'zh' (NOT 'zh-hant' which is the wanted ISO key).
//   Dict has 'zh_hant' key, NOT 'zh-hant'.
// On fix:
//   getLanguage('zh-hant') -> 'zh-hant'
//   getLanguage('zh_hant') -> 'zh-hant'
//   Dict has 'zh-hant' key.

const results = {};

// Case A: zh-hant input must yield 'zh-hant' (fails on base which returns 'zh')
try {
  results.A = exp.getLanguage('zh-hant') === 'zh-hant';
} catch (e) { results.A = false; }

// Case B: en-gb input must yield 'en-gb' (upstream PR's actual fix — hyphen
// inputs, lowercased; underscore normalization is a session-style enhancement
// that the upstream PR did NOT ship).
try {
  results.B = exp.getLanguage('en-gb') === 'en-gb';
} catch (e) { results.B = false; }

// Case C: ZH-HANT yields 'zh-hant' (toLowerCase is in upstream)
try {
  results.C = exp.getLanguage('ZH-HANT') === 'zh-hant';
} catch (e) { results.C = false; }

// Case D: fr-be input must yield 'fr-be' (hyphen-form ISO key)
try {
  results.D = exp.getLanguage('fr-be') === 'fr-be';
} catch (e) { results.D = false; }

// Case E: EN-GB also normalizes via toLowerCase
try {
  results.E = exp.getLanguage('EN-GB') === 'en-gb';
} catch (e) { results.E = false; }

// Case F: dict has hyphenated keys (fails on base which has underscore keys)
let dictHyphen = false;
let dictUnderscore = false;
if (exp.dict && typeof exp.dict === 'object') {
  const keys = Object.keys(exp.dict);
  dictHyphen = keys.includes('zh-hant') && keys.includes('en-gb') && keys.includes('fr-be');
  dictUnderscore = keys.includes('zh_hant') || keys.includes('en_gb') || keys.includes('fr_be');
}
results.F_dict_hyphen = dictHyphen;
results.F_dict_no_underscore = !dictUnderscore;

// Case G: lookup roundtrip — getLanguage output is a valid dict key for
// hyphen-form inputs (the upstream PR's surface).
let lookupOk = false;
if (exp.dict && typeof exp.dict === 'object') {
  try {
    const k1 = exp.getLanguage('zh-hant');
    const k2 = exp.getLanguage('en-gb');
    const k3 = exp.getLanguage('fr-be');
    lookupOk = !!(exp.dict[k1] && exp.dict[k2] && exp.dict[k3])
            && k1 === 'zh-hant' && k2 === 'en-gb' && k3 === 'fr-be';
  } catch (e) { lookupOk = false; }
}
results.G_lookup = lookupOk;

for (const k of Object.keys(results)) {
  console.log(`R_${k}=${results[k] ? '1' : '0'}`);
}
EOF
    OUT=$("$NODE_BIN" "$TMPJS" "$LOCALE_JS" 2>&1)
    EC=$?
    rm -f "$TMPJS"
    echo "$OUT" | sed 's/^/  /'

    if [ "$EC" -eq 0 ]; then
        # Count passing checks
        PASSED=0
        for KEY in R_A R_B R_C R_D R_E R_F_dict_hyphen R_F_dict_no_underscore R_G_lookup; do
            if echo "$OUT" | grep -q "^${KEY}=1"; then
                PASSED=$((PASSED + 1))
            fi
        done
        echo "  Behavioral passes: $PASSED/8"
        # 8 checks * 0.03375 = 0.27 (scaled 0.6x for upstream gates)
        F2P1=$(awk -v p="$PASSED" 'BEGIN { printf "%.4f", p * 0.03375 }')
    fi
fi
echo "  F2P 1 partial: $F2P1"
add "$F2P1"
# Emit gate: passes if behavioral checks succeeded (PASSED counter >= majority)
if [ -n "$F2P1" ] && awk -v v="$F2P1" 'BEGIN{exit (v >= 0.1?0:1)}'; then
    emit_gate "f2p_locale_js_behavioral" true "behavioral getLanguage checks passed"
else
    emit_gate "f2p_locale_js_behavioral" false "behavioral getLanguage checks failed"
fi

###############################################################################
# F2P 2 (0.30): Rust-side underscore→hyphen normalization at locale entry points.
# On buggy base: ACCEPT_LANGUAGE header value passed as-is (.to_string()).
# On fix: normalized via .replace('_', "-") somewhere in the locale flow
# (transformers.rs HeaderPayload, utils.rs get_locale_from_header, or middleware).
# We require the normalization in at least 2 different files OR in a key place.
###############################################################################
echo ""
echo "=== F2P 2: Rust locale normalization (0.18) ==="
F2P2=0
NORM_FILES=0

# Check transformers.rs: locale read with replace
if [ -f "$TRANSFORMERS" ]; then
    # Look for ACCEPT_LANGUAGE block where val is .replace('_', "-")
    if awk '
        /ACCEPT_LANGUAGE/ { in_block=5 }
        in_block > 0 && /replace\(.*_.*-.*\)/ { found=1 }
        in_block > 0 { in_block-- }
        END { exit (found ? 0 : 1) }
    ' "$TRANSFORMERS"; then
        echo "  transformers.rs: normalizes Accept-Language"
        NORM_FILES=$((NORM_FILES + 1))
    fi
fi

# Check utils.rs
if [ -f "$UTILS" ]; then
    if awk '
        /get_locale_from_header/ { in_block=15 }
        in_block > 0 && /replace\(.*_.*-.*\)/ { found=1 }
        in_block > 0 { in_block-- }
        END { exit (found ? 0 : 1) }
    ' "$UTILS"; then
        echo "  utils.rs: get_locale_from_header normalizes"
        NORM_FILES=$((NORM_FILES + 1))
    fi
fi

# Check middleware.rs
if [ -f "$MIDDLEWARE" ]; then
    if awk '
        /locale_param\.locale|ACCEPT_LANGUAGE/ { in_block=10 }
        in_block > 0 && /replace\(.*_.*-.*\)/ { found=1 }
        in_block > 0 { in_block-- }
        END { exit (found ? 0 : 1) }
    ' "$MIDDLEWARE"; then
        echo "  middleware.rs: normalizes locale param"
        NORM_FILES=$((NORM_FILES + 1))
    fi
fi

# Check context.rs: hyphenated keys (en-gb / fr-be) returned
if [ -f "$CONTEXT_RS" ]; then
    if grep -qE '"en-gb"' "$CONTEXT_RS" && grep -qE '"fr-be"' "$CONTEXT_RS"; then
        # Make sure underscored versions aren't still used as the returned key
        if ! grep -qE '"en_gb"\.to_string|"fr_be"\.to_string' "$CONTEXT_RS"; then
            echo "  context.rs: returns hyphenated keys"
            NORM_FILES=$((NORM_FILES + 1))
        fi
    fi
fi

# Other places: payment_link.rs / payment_create.rs / payouts.rs
for EXTRA in \
    "$REPO_DIR/crates/router/src/core/payment_link.rs" \
    "$REPO_DIR/crates/router/src/core/payments/operations/payment_create.rs" \
    "$REPO_DIR/crates/router/src/core/payouts.rs"; do
    if [ -f "$EXTRA" ]; then
        if grep -qE 'locale.*replace\(.*_.*-.*\)|replace\(.*_.*-.*\).*locale' "$EXTRA"; then
            echo "  $(basename $EXTRA): normalizes locale"
            NORM_FILES=$((NORM_FILES + 1))
            break
        fi
    fi
done

echo "  Normalization sites found: $NORM_FILES"
# The upstream PR (juspay/hyperswitch#9064) does NOT touch any Rust file —
# it's a pure JS-side dict-key migration. Rust normalization is a session-style
# enhancement (changing how Accept-Language is parsed). Award full credit if
# present (the agent went above-and-beyond canonical scope) but do NOT penalise
# its absence — drop the gate's weight to 0 when 0 normalisation sites exist
# AND the JS dict was migrated (F2P 3 covers that surface).
if [ "$NORM_FILES" -ge 2 ]; then
    F2P2=0.18
elif [ "$NORM_FILES" -eq 1 ]; then
    F2P2=0.108
else
    # Canonical-state credit: the upstream PR shipped without Rust changes.
    # Award the gate's weight if the JS dict was migrated (canonical proof).
    if grep -qE "[\"']en-gb[\"'][[:space:]]*:" "$LOCALE_JS" 2>/dev/null \
       && grep -qE "[\"']fr-be[\"'][[:space:]]*:" "$LOCALE_JS" 2>/dev/null \
       && grep -qE "[\"']zh-hant[\"'][[:space:]]*:" "$LOCALE_JS" 2>/dev/null; then
        F2P2=0.18
        echo "  (canonical-equivalent: JS dict migrated; Rust normalization not required by upstream PR)"
    fi
fi
echo "  F2P 2 partial: $F2P2"
add "$F2P2"
if [ -n "$F2P2" ] && awk -v v="$F2P2" 'BEGIN{exit (v >= 0.05?0:1)}'; then
    emit_gate "f2p_rust_locale_normalization" true "Rust normalization or canonical-equivalent JS dict migration"
else
    emit_gate "f2p_rust_locale_normalization" false "no Rust normalization and no canonical JS dict"
fi

###############################################################################
# F2P 3 (0.15): locale.js dictionary keys are hyphenated, not underscored.
# Direct grep-based check (structural but tied to the bug — base FAILS this).
###############################################################################
echo ""
echo "=== F2P 3: locale.js dict key migration (0.09) ==="
F2P3=0
HAS_HYPHEN_KEYS=0
HAS_UNDERSCORE_KEYS=0

# Hyphenated keys: "en-gb" or 'en-gb' as object property
if grep -qE "[\"']en-gb[\"'][[:space:]]*:" "$LOCALE_JS" \
   && grep -qE "[\"']fr-be[\"'][[:space:]]*:" "$LOCALE_JS" \
   && grep -qE "[\"']zh-hant[\"'][[:space:]]*:" "$LOCALE_JS"; then
    HAS_HYPHEN_KEYS=1
fi

# Underscore keys still present as object properties
if grep -qE "(^|[[:space:]])en_gb[[:space:]]*:" "$LOCALE_JS" \
   || grep -qE "(^|[[:space:]])fr_be[[:space:]]*:" "$LOCALE_JS" \
   || grep -qE "(^|[[:space:]])zh_hant[[:space:]]*:" "$LOCALE_JS"; then
    HAS_UNDERSCORE_KEYS=1
fi

echo "  hyphen_keys=$HAS_HYPHEN_KEYS underscore_keys=$HAS_UNDERSCORE_KEYS"
if [ "$HAS_HYPHEN_KEYS" = "1" ] && [ "$HAS_UNDERSCORE_KEYS" = "0" ]; then
    F2P3=0.09
elif [ "$HAS_HYPHEN_KEYS" = "1" ]; then
    F2P3=0.042
fi
echo "  F2P 3 partial: $F2P3"
add "$F2P3"
if [ -n "$F2P3" ] && awk -v v="$F2P3" 'BEGIN{exit (v >= 0.03?0:1)}'; then
    emit_gate "f2p_locale_js_dict_keys" true "dict keys hyphenated"
else
    emit_gate "f2p_locale_js_dict_keys" false "dict keys not migrated to hyphens"
fi

###############################################################################
# F2P 4 (0.10): locale.js getLanguage uses hyphen-based key construction.
# On buggy base: `${language}_${country}` — F2P 4 fails.
# On fix: hyphen-based key construction OR cases that return hyphenated keys.
###############################################################################
echo ""
echo "=== F2P 4: getLanguage hyphen-based (0.06) ==="
F2P4=0
# Extract the getLanguage function body (rough)
GETLANG_BODY=$(awk '/function getLanguage/,/^}/' "$LOCALE_JS")
if echo "$GETLANG_BODY" | grep -qE "['\"]zh-hant['\"]|['\"]en-gb['\"]|['\"]fr-be['\"]" \
   || echo "$GETLANG_BODY" | grep -qE 'replace\(.*_.*-.*\)'; then
    # And NOT returning underscore variants
    if ! echo "$GETLANG_BODY" | grep -qE "return ['\"]en_gb['\"]|return ['\"]fr_be['\"]|return ['\"]zh_hant['\"]"; then
        F2P4=0.06
    else
        F2P4=0.03
    fi
fi
echo "  F2P 4 partial: $F2P4"
add "$F2P4"
if [ -n "$F2P4" ] && awk -v v="$F2P4" 'BEGIN{exit (v >= 0.01?0:1)}'; then
    emit_gate "f2p_getlanguage_hyphen" true "getLanguage uses hyphenated keys"
else
    emit_gate "f2p_getlanguage_hyphen" false "getLanguage still underscore-based"
fi

###############################################################################
# Final
###############################################################################
echo ""
echo "================================================"
echo "TOTAL REWARD: $REWARD"
echo "================================================"

# Clamp [0, 1]
REWARD=$(awk -v r="$REWARD" 'BEGIN {
  if (r < 0) r = 0;
  if (r > 1) r = 1;
  printf "%.4f", r;
}')

echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
# Prelude: ensure node is available
if ! command -v node >/dev/null 2>&1; then
    sudo apt-get install -y nodejs 2>/dev/null || true
fi

GATES_FILE="/logs/verifier/gates.json"
# Do NOT truncate $GATES_FILE here — earlier inline emit_gate calls already wrote
# our 4 inline F2P gates. Append-only from here on.

# F2P upstream gate 1: getLanguage behavioral test
echo ""
echo "=== Upstream F2P 1: locale.js getLanguage behavioral (0.20) ==="
F2P_U1_PASSED=false
if command -v node >/dev/null 2>&1 && [ -f "$LOCALE_JS" ]; then
    TMPJS=$(mktemp /tmp/gate_u1_XXXXXX.js)
    cat > "$TMPJS" <<'GATEJS1'
const fs=require('fs');
const src=fs.readFileSync(process.argv[2],'utf8');
const w=src+';module.exports={getLanguage,locales};';
const M=require('module');
const m=new M('l');
m._compile(w,'l.js');
const e=m.exports;
const tests=[['zh-hant','zh-hant'],['en-gb','en-gb'],['fr-be','fr-be'],['ZH-HANT','zh-hant']];
let ok=true;
for(const[i,x]of tests){if(e.getLanguage(i)!==x){ok=false;console.log('FAIL:',i,'->',e.getLanguage(i),'expected',x);}}
const k=Object.keys(e.locales);
if(!k.includes('zh-hant')||!k.includes('en-gb')||!k.includes('fr-be')){ok=false;console.log('FAIL: missing hyphenated dict keys');}
if(k.includes('zh_hant')||k.includes('en_gb')||k.includes('fr_be')){ok=false;console.log('FAIL: underscore dict keys still present');}
if(ok)console.log('PASS: all getLanguage and dict key checks passed');
process.exit(ok?0:1);
GATEJS1
    node "$TMPJS" "$LOCALE_JS" 2>&1 | sed 's/^/  /'
    if [ ${PIPESTATUS[0]} -eq 0 ]; then F2P_U1_PASSED=true; fi
    rm -f "$TMPJS"
fi
echo "  upstream_f2p_1=$F2P_U1_PASSED"
echo "{\"id\":\"f2p_upstream_locale_js_getlang\",\"passed\":$F2P_U1_PASSED,\"detail\":\"getLanguage returns hyphenated keys and dict uses hyphens\"}" >> "$GATES_FILE"

# F2P upstream gate 2: getTranslations roundtrip
echo ""
echo "=== Upstream F2P 2: locale.js getTranslations roundtrip (0.20) ==="
F2P_U2_PASSED=false
if command -v node >/dev/null 2>&1 && [ -f "$LOCALE_JS" ]; then
    TMPJS=$(mktemp /tmp/gate_u2_XXXXXX.js)
    cat > "$TMPJS" <<'GATEJS2'
const fs=require('fs');
const src=fs.readFileSync(process.argv[2],'utf8');
const w=src+';module.exports={getTranslations,locales};';
const M=require('module');
const m=new M('l');
m._compile(w,'l.js');
const e=m.exports;
const t=e.getTranslations('zh-hant');
const isTraditional=t&&t.expiresOn&&t.expiresOn.includes('\u9023\u7d50');
const t2=e.getTranslations('en-gb');
const isBritish=t2&&t2.expiresOn&&t2.expiresOn.startsWith('Link');
const ok=isTraditional&&isBritish;
if(!ok){console.log('FAIL:','zh-hant expiresOn:',t?t.expiresOn:'null','en-gb expiresOn:',t2?t2.expiresOn:'null');}
else{console.log('PASS: zh-hant gets Traditional Chinese, en-gb gets British English');}
process.exit(ok?0:1);
GATEJS2
    node "$TMPJS" "$LOCALE_JS" 2>&1 | sed 's/^/  /'
    if [ ${PIPESTATUS[0]} -eq 0 ]; then F2P_U2_PASSED=true; fi
    rm -f "$TMPJS"
fi
echo "  upstream_f2p_2=$F2P_U2_PASSED"
echo "{\"id\":\"f2p_upstream_locale_js_roundtrip\",\"passed\":$F2P_U2_PASSED,\"detail\":\"getTranslations zh-hant returns Traditional Chinese\"}" >> "$GATES_FILE"

# P2P upstream gate 1: node --check locale.js
echo ""
echo "=== Upstream P2P 1: node --check locale.js ==="
P2P_U1_PASSED=false
if command -v node >/dev/null 2>&1 && [ -f "$LOCALE_JS" ]; then
    if node --check "$LOCALE_JS" 2>&1; then
        P2P_U1_PASSED=true
    fi
fi
echo "  upstream_p2p_1=$P2P_U1_PASSED"
echo "{\"id\":\"p2p_upstream_node_check_locale\",\"passed\":$P2P_U1_PASSED,\"detail\":\"locale.js passes node syntax check\"}" >> "$GATES_FILE"

# P2P upstream gate 2: changed files exist
echo ""
echo "=== Upstream P2P 2: changed files exist ==="
P2P_U2_PASSED=true
for f in "$LOCALE_JS" "$CONTEXT_RS" "$TRANSFORMERS"; do
    if [ ! -f "$f" ]; then P2P_U2_PASSED=false; echo "  MISSING: $f"; fi
done
echo "  upstream_p2p_2=$P2P_U2_PASSED"
echo "{\"id\":\"p2p_upstream_files_exist\",\"passed\":$P2P_U2_PASSED,\"detail\":\"all 3 changed files exist\"}" >> "$GATES_FILE"

# Upstream reward tail
python3 - <<'PYEOF'
import json, os

WEIGHTS = {"f2p_upstream_locale_js_getlang": 0.20, "f2p_upstream_locale_js_roundtrip": 0.20}
P2P_REGRESSION = ["p2p_upstream_node_check_locale", "p2p_upstream_files_exist"]

verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass

existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
# weighted-replace formula (c8bc168a standard, replaces additive)
inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f (existing=%.4f)' % (reward, existing))
PYEOF
# ---- end ----

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
