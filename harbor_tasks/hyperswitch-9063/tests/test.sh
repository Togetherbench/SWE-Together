#!/bin/bash
set +e
# [v041-fix] rustup default stable
if command -v rustup >/dev/null 2>&1; then
    rustup default stable >/dev/null 2>&1 || true
fi
export PATH="/usr/local/cargo/bin:/root/.cargo/bin:$PATH"


REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

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

###############################################################################
# F2P 1 (0.45): Behavioral test of locale.js getLanguage().
# On buggy base: getLanguage('zh_hant') returns 'zh' (because key uses underscore
# but split is on '-' so country=null), or returns 'zh_null', etc.
# On fix: getLanguage('zh_hant') returns 'zh-hant' (or at minimum, dictionary
# keys are hyphenated and underscores are normalized).
###############################################################################
echo "=== F2P 1: locale.js behavioral (0.45) ==="
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
  dict: (typeof translations !== 'undefined') ? translations
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

// Case B: zh_hant input must yield 'zh-hant' (fails on base)
try {
  results.B = exp.getLanguage('zh_hant') === 'zh-hant';
} catch (e) { results.B = false; }

// Case C: ZH-HANT yields 'zh-hant'
try {
  results.C = exp.getLanguage('ZH-HANT') === 'zh-hant';
} catch (e) { results.C = false; }

// Case D: en_gb yields 'en-gb' (fails on base which returns 'en_gb' but key not in hyphen dict)
try {
  results.D = exp.getLanguage('en_gb') === 'en-gb';
} catch (e) { results.D = false; }

// Case E: fr_be yields 'fr-be'
try {
  results.E = exp.getLanguage('fr_be') === 'fr-be';
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

// Case G: lookup roundtrip — getLanguage output is a valid dict key
let lookupOk = false;
if (exp.dict && typeof exp.dict === 'object') {
  try {
    const k1 = exp.getLanguage('zh_hant');
    const k2 = exp.getLanguage('en_gb');
    const k3 = exp.getLanguage('fr_be');
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
        # 8 checks * 0.05625 = 0.45
        F2P1=$(awk -v p="$PASSED" 'BEGIN { printf "%.4f", p * 0.05625 }')
    fi
fi
echo "  F2P 1 partial: $F2P1"
add "$F2P1"

###############################################################################
# F2P 2 (0.30): Rust-side underscore→hyphen normalization at locale entry points.
# On buggy base: ACCEPT_LANGUAGE header value passed as-is (.to_string()).
# On fix: normalized via .replace('_', "-") somewhere in the locale flow
# (transformers.rs HeaderPayload, utils.rs get_locale_from_header, or middleware).
# We require the normalization in at least 2 different files OR in a key place.
###############################################################################
echo ""
echo "=== F2P 2: Rust locale normalization (0.30) ==="
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
if [ "$NORM_FILES" -ge 2 ]; then
    F2P2=0.30
elif [ "$NORM_FILES" -eq 1 ]; then
    F2P2=0.18
fi
echo "  F2P 2 partial: $F2P2"
add "$F2P2"

###############################################################################
# F2P 3 (0.15): locale.js dictionary keys are hyphenated, not underscored.
# Direct grep-based check (structural but tied to the bug — base FAILS this).
###############################################################################
echo ""
echo "=== F2P 3: locale.js dict key migration (0.15) ==="
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
    F2P3=0.15
elif [ "$HAS_HYPHEN_KEYS" = "1" ]; then
    F2P3=0.07
fi
echo "  F2P 3 partial: $F2P3"
add "$F2P3"

###############################################################################
# F2P 4 (0.10): locale.js getLanguage uses hyphen-based key construction.
# On buggy base: `${language}_${country}` — F2P 4 fails.
# On fix: hyphen-based key construction OR cases that return hyphenated keys.
###############################################################################
echo ""
echo "=== F2P 4: getLanguage hyphen-based (0.10) ==="
F2P4=0
# Extract the getLanguage function body (rough)
GETLANG_BODY=$(awk '/function getLanguage/,/^}/' "$LOCALE_JS")
if echo "$GETLANG_BODY" | grep -qE "['\"]zh-hant['\"]|['\"]en-gb['\"]|['\"]fr-be['\"]" \
   || echo "$GETLANG_BODY" | grep -qE 'replace\(.*_.*-.*\)'; then
    # And NOT returning underscore variants
    if ! echo "$GETLANG_BODY" | grep -qE "return ['\"]en_gb['\"]|return ['\"]fr_be['\"]|return ['\"]zh_hant['\"]"; then
        F2P4=0.10
    else
        F2P4=0.05
    fi
fi
echo "  F2P 4 partial: $F2P4"
add "$F2P4"

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