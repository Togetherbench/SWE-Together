#!/bin/bash
set +e

# Test: Verify underscore-to-hyphen locale fix in hyperswitch
# Strategy: behavioral JS test via node (dominates), Rust normalization checks
# (regex match on entry points), structural checks on locale.js dict keys.

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

# Locate repo
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
if [ -z "$REPO_DIR" ] || [ ! -d "$REPO_DIR/.git" ]; then
    echo "FAIL: repo not found"
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

echo "Repo: $REPO_DIR"
cd "$REPO_DIR" || { echo "0.0" > "$REWARD_FILE"; exit 0; }
git config --global --add safe.directory "$REPO_DIR" 2>/dev/null

LOCALE_JS="$REPO_DIR/crates/router/src/core/payment_link/locale.js"
TRANSFORMERS="$REPO_DIR/crates/router/src/types/transformers.rs"
UTILS="$REPO_DIR/crates/router/src/utils.rs"
CONTEXT_RS="$REPO_DIR/crates/router/src/services/api/generic_link_response/context.rs"
MIDDLEWARE="$REPO_DIR/crates/router/src/middleware.rs"

REWARD=0
add() {
    REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN { printf "%.4f", a + b }')
}

# Detect node
NODE_BIN=""
for n in node nodejs; do
    if command -v "$n" >/dev/null 2>&1; then NODE_BIN="$n"; break; fi
done
if [ -z "$NODE_BIN" ]; then
    export PATH="/usr/local/bin:/usr/bin:$PATH"
    for n in node nodejs; do
        if command -v "$n" >/dev/null 2>&1; then NODE_BIN="$n"; break; fi
    done
fi

###############################################################################
# CHECK 1 (0.10) — Regression / engagement guard
# Files exist, modifications happened, no insane mass deletion.
###############################################################################
echo ""
echo "=== Check 1: engagement & regression guard (0.10) ==="
ENG_OK=0
if [ -f "$LOCALE_JS" ]; then
    BASE_COMMIT=$(git log --reverse --format=%H 2>/dev/null | head -1)
    DIFF=$(git diff HEAD~5 HEAD 2>/dev/null)
    [ -z "$DIFF" ] && DIFF=$(git diff 2>/dev/null)
    [ -z "$DIFF" ] && DIFF=$(git log -1 -p 2>/dev/null)
    ADDED=$(echo "$DIFF" | grep -c "^+[^+]")
    REMOVED=$(echo "$DIFF" | grep -c "^-[^-]")
    echo "  diff +$ADDED / -$REMOVED"
    # Some change must exist; reject mass deletes (>2000 lines)
    if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
        if [ "$REMOVED" -lt 2000 ]; then
            ENG_OK=1
        fi
    fi
    # locale.js must still parse / not be empty
    if [ ! -s "$LOCALE_JS" ]; then
        ENG_OK=0
    fi
fi
if [ "$ENG_OK" = "1" ]; then
    echo "  PASS"
    add 0.10
else
    echo "  FAIL"
fi

###############################################################################
# CHECK 2 (0.40) — BEHAVIORAL: locale.js getLanguage() must produce
# correct dictionary keys for ISO inputs incl. underscore variants.
# The dictionary lookup must succeed for the returned key.
###############################################################################
echo ""
echo "=== Check 2: locale.js behavioral via node (0.40) ==="
B_PASS=0; B_TOTAL=0
DICT_HYPHEN=0; DICT_UNDER=0
GETLANG_OK=0

if [ -z "$NODE_BIN" ] || [ ! -f "$LOCALE_JS" ]; then
    echo "  node or locale.js missing — falling back to structural checks"
else
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

// Cases: input -> expected returned key (must also be a valid dict key when applicable)
const cases = [
  ['zh-hant',        'zh-hant'],
  ['zh_hant',        'zh-hant'],
  ['ZH-HANT',        'zh-hant'],
  ['Zh',             'zh'],
  ['zh',             'zh'],
  ['zh-abcdef',      'zh'],
  ['en-gb',          'en-gb'],
  ['en_gb',          'en-gb'],
  ['EN_GB',          'en-gb'],
  ['fr-be',          'fr-be'],
  ['fr_be',          'fr-be'],
  ['en',             'en'],
  ['fr',             'fr'],
];

let pass = 0;
const lines = [];
for (const [inp, want] of cases) {
  let got;
  try { got = exp.getLanguage(inp); } catch (e) { got = 'ERR:' + e.message; }
  let ok = (got === want);
  // Tolerate zh-hant-abcdef-style tail truncation matches not in this list
  if (ok) pass++;
  lines.push(`${inp} -> ${got} (want ${want}) ${ok ? 'OK' : 'FAIL'}`);
}
// Tail-tolerance separate case
{
  let got;
  try { got = exp.getLanguage('zh-hant-abcdef'); } catch (e) { got = 'ERR'; }
  const ok = (got === 'zh-hant' || got === 'zh');
  if (ok) pass++;
  lines.push(`zh-hant-abcdef -> ${got} (want zh-hant or zh) ${ok ? 'OK' : 'FAIL'}`);
}

const total = cases.length + 1;
console.log(lines.join('\n'));
console.log(`SUMMARY ${pass}/${total}`);

// Inspect dictionary keys
if (exp.dict && typeof exp.dict === 'object') {
  const keys = Object.keys(exp.dict);
  const hasHy = keys.some(k => k === 'en-gb' || k === 'fr-be' || k === 'zh-hant');
  const hasUn = keys.some(k => k === 'en_gb' || k === 'fr_be' || k === 'zh_hant');
  console.log(`DICT hyphen=${hasHy} underscore=${hasUn}`);

  // Lookup test: getLanguage's output for underscore inputs should produce a
  // key that exists in the dict (where applicable).
  const lookups = [
    ['zh_hant', 'zh-hant'],
    ['en_gb',   'en-gb'],
    ['fr_be',   'fr-be'],
  ];
  let lookupPass = 0;
  for (const [inp, expectKey] of lookups) {
    const got = exp.getLanguage(inp);
    if (got === expectKey && exp.dict[got]) lookupPass++;
  }
  console.log(`LOOKUP ${lookupPass}/${lookups.length}`);
} else {
  console.log('DICT none');
  console.log('LOOKUP 0/3');
}
EOF
    OUT=$("$NODE_BIN" "$TMPJS" "$LOCALE_JS" 2>&1)
    EC=$?
    rm -f "$TMPJS"
    echo "$OUT" | sed 's/^/  /'

    if [ "$EC" -eq 0 ]; then
        GETLANG_OK=1
        SUMMARY=$(echo "$OUT" | grep "^SUMMARY" | tail -1)
        B_PASS=$(echo "$SUMMARY" | awk '{print $2}' | cut -d/ -f1)
        B_TOTAL=$(echo "$SUMMARY" | awk '{print $2}' | cut -d/ -f2)
        DICTLINE=$(echo "$OUT" | grep "^DICT" | tail -1)
        echo "$DICTLINE" | grep -q "hyphen=true"  && DICT_HYPHEN=1
        echo "$DICTLINE" | grep -q "underscore=true" && DICT_UNDER=1
        LOOKUPLINE=$(echo "$OUT" | grep "^LOOKUP" | tail -1)
        LOOKUP_PASS=$(echo "$LOOKUPLINE" | awk '{print $2}' | cut -d/ -f1)
        [ -z "$LOOKUP_PASS" ] && LOOKUP_PASS=0
    fi
fi

# Score check 2:
#  - 0.25 weight for getLanguage cases (>=12/14 → full, >=8 → half)
#  - 0.10 weight for dict-key migration (hyphen present & underscore absent → full;
#                                        hyphen present but underscore lingering → half)
#  - 0.05 for cross-lookup (getLanguage out resolves into dict)
[ -z "$B_PASS" ] && B_PASS=0
[ -z "$B_TOTAL" ] && B_TOTAL=14
[ -z "$LOOKUP_PASS" ] && LOOKUP_PASS=0

GETLANG_PART=0
if [ "$GETLANG_OK" = "1" ]; then
    if [ "$B_PASS" -ge $((B_TOTAL - 2)) ]; then
        GETLANG_PART=0.25
    elif [ "$B_PASS" -ge $((B_TOTAL / 2)) ]; then
        GETLANG_PART=0.12
    fi
fi
DICT_PART=0
if [ "$DICT_HYPHEN" = "1" ] && [ "$DICT_UNDER" = "0" ]; then
    DICT_PART=0.10
elif [ "$DICT_HYPHEN" = "1" ]; then
    DICT_PART=0.05
fi
LOOKUP_PART=0
if [ "$LOOKUP_PASS" -ge 3 ]; then
    LOOKUP_PART=0.05
elif [ "$LOOKUP_PASS" -ge 1 ]; then
    LOOKUP_PART=0.02
fi

# Fallback structural if node unavailable
if [ "$GETLANG_OK" = "0" ] && [ -f "$LOCALE_JS" ]; then
    if grep -qE "['\"]zh-hant['\"]" "$LOCALE_JS"; then GETLANG_PART=0.12; fi
    if grep -qE "['\"]en-gb['\"]" "$LOCALE_JS" && grep -qE "['\"]fr-be['\"]" "$LOCALE_JS"; then
        DICT_PART=0.05
        if ! grep -qE "['\"]en_gb['\"]" "$LOCALE_JS" && ! grep -qE "['\"]fr_be['\"]" "$LOCALE_JS" && ! grep -qE "['\"]zh_hant['\"]" "$LOCALE_JS"; then
            DICT_PART=0.10
        fi
    fi
fi

C2_TOTAL=$(awk -v a="$GETLANG_PART" -v b="$DICT_PART" -v c="$LOOKUP_PART" 'BEGIN { printf "%.4f", a + b + c }')
echo "  getLang=$GETLANG_PART dict=$DICT_PART lookup=$LOOKUP_PART -> $C2_TOTAL / 0.40"
add "$C2_TOTAL"

###############################################################################
# CHECK 3 (0.25) — Behavioral-equivalent: Rust entry points normalize
# underscore -> hyphen for incoming locale.
# We require AT LEAST ONE of the standard entry points to apply the
# replace('_', "-") transformation. Strong fixes touch multiple.
###############################################################################
echo ""
echo "=== Check 3: Rust normalization at locale entry points (0.25) ==="

count_norm_in_block() {
    # $1 file, $2 anchor regex, $3 lines after
    local f="$1" pat="$2" n="$3"
    [ -f "$f" ] || { echo 0; return; }
    awk -v pat="$pat" -v n="$n" '
        $0 ~ pat { found=1; count=0 }
        found && count<=n { print; count++ }
        found && count>n { found=0 }
    ' "$f" | grep -cE 'replace\(.[_].,\s*"-"\)'
}

NORM_TRANSFORMERS=0
NORM_UTILS=0
NORM_MIDDLEWARE=0
NORM_OTHER=0

if [ -f "$TRANSFORMERS" ]; then
    # Count occurrences where ACCEPT_LANGUAGE block is followed (within ~5 lines) by replace('_', "-")
    # Simpler: any line within 4 of an ACCEPT_LANGUAGE that contains the replace pattern.
    HITS=$(awk '
        /ACCEPT_LANGUAGE/ { window=5 }
        window>0 { print; window-- }
    ' "$TRANSFORMERS" | grep -cE "replace\(.[_].,\s*\"-\"\)")
    NORM_TRANSFORMERS=$HITS
    echo "  transformers.rs ACCEPT_LANGUAGE-adjacent normalizations: $HITS"
fi

if [ -f "$UTILS" ]; then
    BLOCK=$(awk '/fn get_locale_from_header/,/^}/' "$UTILS")
    if echo "$BLOCK" | grep -qE "replace\(.[_].,\s*\"-\"\)"; then
        NORM_UTILS=1
    fi
    echo "  utils.rs get_locale_from_header normalizes: $NORM_UTILS"
fi

if [ -f "$MIDDLEWARE" ]; then
    # Look for locale_param.locale or ACCEPT_LANGUAGE setter region with replace
    if grep -A 8 "locale_param" "$MIDDLEWARE" 2>/dev/null | grep -qE "replace\(.[_].,\s*\"-\"\)"; then
        NORM_MIDDLEWARE=1
    fi
    echo "  middleware.rs locale_param normalizes: $NORM_MIDDLEWARE"
fi

# Count broader normalizations across crates/router/src as backstop
NORM_OTHER=$(grep -rE "replace\(.[_].,\s*\"-\"\)" "$REPO_DIR/crates/router/src" 2>/dev/null | wc -l)
echo "  total replace('_', \"-\") occurrences in crates/router/src: $NORM_OTHER"

# Score:
#  - 0.10 if at least one Rust entry point (transformers/utils/middleware) normalizes
#  - +0.10 if two of the three normalize
#  - +0.05 if three of the three (or transformers has >=2 matches AND utils OR middleware)
TIER=0
[ "$NORM_TRANSFORMERS" -ge 1 ] && TIER=$((TIER+1))
[ "$NORM_UTILS" -ge 1 ]        && TIER=$((TIER+1))
[ "$NORM_MIDDLEWARE" -ge 1 ]   && TIER=$((TIER+1))

C3=0
if [ "$TIER" -ge 3 ]; then
    C3=0.25
elif [ "$TIER" -eq 2 ]; then
    C3=0.18
elif [ "$TIER" -eq 1 ]; then
    C3=0.10
elif [ "$NORM_OTHER" -ge 1 ]; then
    # Some normalization somewhere — minimal credit
    C3=0.05
fi
echo "  tier=$TIER → +$C3"
add "$C3"

###############################################################################
# CHECK 4 (0.15) — Structural: generic_link_response/context.rs locale match
# now returns hyphenated keys (en-gb, fr-be).
###############################################################################
echo ""
echo "=== Check 4: context.rs locale construction uses hyphens (0.15) ==="
C4=0
if [ -f "$CONTEXT_RS" ]; then
    BLOCK=$(awk '/match \(language, country\)/,/^[[:space:]]*\}/' "$CONTEXT_RS")
    if [ -z "$BLOCK" ]; then
        BLOCK=$(grep -E "(\"en\".*gb|\"fr\".*be)" "$CONTEXT_RS")
    fi
    HAS_HY=0; HAS_UN=0
    echo "$BLOCK" | grep -qE '"en-gb"' && HAS_HY=$((HAS_HY+1))
    echo "$BLOCK" | grep -qE '"fr-be"' && HAS_HY=$((HAS_HY+1))
    echo "$BLOCK" | grep -qE '"en_gb"' && HAS_UN=$((HAS_UN+1))
    echo "$BLOCK" | grep -qE '"fr_be"' && HAS_UN=$((HAS_UN+1))
    echo "  hyphen-keys=$HAS_HY underscore-keys=$HAS_UN"
    if [ "$HAS_HY" -ge 2 ] && [ "$HAS_UN" -eq 0 ]; then
        C4=0.15
    elif [ "$HAS_HY" -ge 1 ] && [ "$HAS_UN" -eq 0 ]; then
        C4=0.10
    elif [ "$HAS_HY" -ge 1 ]; then
        C4=0.05
    fi
else
    echo "  context.rs not present — partial credit if locale.js dict already migrated"
    if [ "$DICT_HYPHEN" = "1" ] && [ "$DICT_UNDER" = "0" ]; then
        C4=0.05
    fi
fi
echo "  -> +$C4"
add "$C4"

###############################################################################
# CHECK 5 (0.10) — Anti-regression: no obvious leftover "en_gb"/"fr_be"/"zh_hant"
# AS DICTIONARY KEYS in locale.js (comments tolerated).
###############################################################################
echo ""
echo "=== Check 5: no underscore dict keys lingering in locale.js (0.10) ==="
C5=0
if [ -f "$LOCALE_JS" ]; then
    LEFTOVER=0
    # Patterns that look like an object key: en_gb: { OR "en_gb": { OR 'en_gb': {
    for k in en_gb fr_be zh_hant; do
        if grep -E "(^|[^A-Za-z0-9_])(['\"]?)${k}\2[[:space:]]*:[[:space:]]*\{" "$LOCALE_JS" >/dev/null; then
            LEFTOVER=$((LEFTOVER+1))
            echo "  leftover key: $k"
        fi
    done
    if [ "$LEFTOVER" -eq 0 ]; then
        C5=0.10
        echo "  PASS"
    elif [ "$LEFTOVER" -le 1 ]; then
        C5=0.04
        echo "  PARTIAL"
    else
        echo "  FAIL"
    fi
else
    echo "  locale.js missing"
fi
add "$C5"

###############################################################################
# Finalize
###############################################################################
# Clamp to [0,1]
REWARD=$(awk -v r="$REWARD" 'BEGIN {
    if (r<0) r=0; if (r>1) r=1; printf "%.4f", r
}')
echo ""
echo "=============================="
echo "FINAL REWARD: $REWARD"
echo "=============================="
echo "$REWARD" > "$REWARD_FILE"
exit 0