#!/bin/bash
set +e

REPO="/workspace/pi-mono"
LOG="/logs/verifier/details.log"
mkdir -p /logs/verifier
echo "=== Verifier Start ===" > "$LOG"

REWARD=0.0
echo "$REWARD" > /logs/verifier/reward.txt

if [ ! -d "$REPO" ]; then
    echo "FATAL: $REPO not found" >> "$LOG"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

cd "$REPO"

export PATH="/usr/local/bin:/usr/bin:/bin:/root/.bun/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
    for cand in /usr/local/bin/node /usr/bin/node /root/.nvm/versions/node/*/bin/node; do
        if [ -x "$cand" ]; then
            export PATH="$(dirname $cand):$PATH"
            break
        fi
    done
fi

if ! command -v node >/dev/null 2>&1; then
    echo "FATAL: node missing" >> "$LOG"
    echo "0.0" > /logs/verifier/reward.txt
    exit 0
fi

# Enumerate workspace package.json files (only packages/* + root)
PKG_JSONS=()
for pj in "$REPO"/packages/*/package.json "$REPO"/package.json; do
    [ -f "$pj" ] && PKG_JSONS+=("$pj")
done
echo "Found ${#PKG_JSONS[@]} package.json files" >> "$LOG"

# -----------------------------------------------------------------------------
# P2P GATE (gating only): all package.json valid + retain name field
# -----------------------------------------------------------------------------
for pj in "${PKG_JSONS[@]}"; do
    OK=$(node -e "
        try {
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            if (typeof d.name === 'string' && d.name.length > 0) console.log('ok');
        } catch(e) {}
    " 2>/dev/null)
    if [ "$OK" != "ok" ]; then
        echo "P2P FAIL: $pj invalid or missing name -> reward 0" >> "$LOG"
        echo "0.0" > /logs/verifier/reward.txt
        exit 0
    fi
done
echo "P2P PASS: all package.json valid" >> "$LOG"

# Set of in-scope publishable packages that should receive the keyword.
# Derived from looking at the captured strong fixes (Opus, Kimi, GLM4.7, MiniMax)
# all touched these 7 packages.
EXPECTED_PKGS=(agent ai coding-agent mom pods tui web-ui)

# Helper: read keyword presence per expected package, into arrays
NEW_PI_PKGS=""
BASELINE_PI_PKGS=""

# Build baseline using git HEAD if available, else derive baseline as
# packages whose ORIGINAL keywords already include pi-package.
declare -A BASELINE_HAS

if [ -d "$REPO/.git" ] && command -v git >/dev/null 2>&1; then
    for name in "${EXPECTED_PKGS[@]}"; do
        REL="packages/$name/package.json"
        ORIG=$(git -C "$REPO" show "HEAD:$REL" 2>/dev/null)
        HAS="no"
        if [ -n "$ORIG" ]; then
            HAS=$(echo "$ORIG" | node -e "
                let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
                    try {
                        const d = JSON.parse(s);
                        const kw = Array.isArray(d.keywords) ? d.keywords.map(x=>String(x).toLowerCase()) : [];
                        if (kw.includes('pi-package')) console.log('yes'); else console.log('no');
                    } catch(e) { console.log('no'); }
                });
            " 2>/dev/null)
        fi
        BASELINE_HAS[$name]="$HAS"
    done
else
    for name in "${EXPECTED_PKGS[@]}"; do
        BASELINE_HAS[$name]="no"
    done
fi

# Count newly-added pi-package keywords across expected packages
NEW_PI_COUNT=0
TOTAL_EXPECTED_NEEDED=0
for name in "${EXPECTED_PKGS[@]}"; do
    if [ "${BASELINE_HAS[$name]}" = "no" ]; then
        TOTAL_EXPECTED_NEEDED=$((TOTAL_EXPECTED_NEEDED + 1))
    fi
done
echo "Expected packages needing keyword (not in baseline): $TOTAL_EXPECTED_NEEDED" >> "$LOG"

for name in "${EXPECTED_PKGS[@]}"; do
    pj="$REPO/packages/$name/package.json"
    [ ! -f "$pj" ] && continue
    HAS_KW=$(node -e "
        try {
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            const kw = Array.isArray(d.keywords) ? d.keywords : [];
            if (kw.map(x => String(x).toLowerCase()).includes('pi-package')) console.log('yes');
            else console.log('no');
        } catch(e) { console.log('no'); }
    " 2>/dev/null)
    if [ "$HAS_KW" = "yes" ] && [ "${BASELINE_HAS[$name]}" = "no" ]; then
        NEW_PI_PKGS="$NEW_PI_PKGS $name"
        NEW_PI_COUNT=$((NEW_PI_COUNT + 1))
    fi
done
echo "Newly-added pi-package packages: [$NEW_PI_PKGS ] count=$NEW_PI_COUNT" >> "$LOG"

# -----------------------------------------------------------------------------
# GATE A (weight 0.20): At least one package.json got pi-package added.
# Filters out no-op patches and doc-only patches.
# -----------------------------------------------------------------------------
GATE_A_AWK=0
if [ "$NEW_PI_COUNT" -ge 1 ]; then
    GATE_A_AWK=20
fi
echo "GATE_A (any new keyword): NEW=$NEW_PI_COUNT -> $GATE_A_AWK/20" >> "$LOG"

# -----------------------------------------------------------------------------
# GATE B (weight 0.30): Breadth - majority of expected packages got it.
# Tiered against TOTAL_EXPECTED_NEEDED (typically 7).
#   < 25% -> 0
#   25-49% -> 10
#   50-74% -> 20
#   >= 75% -> 30
# -----------------------------------------------------------------------------
GATE_B_AWK=0
if [ "$TOTAL_EXPECTED_NEEDED" -gt 0 ]; then
    PCT=$(awk "BEGIN { printf \"%d\", ($NEW_PI_COUNT * 100) / $TOTAL_EXPECTED_NEEDED }")
    if [ "$PCT" -ge 75 ]; then
        GATE_B_AWK=30
    elif [ "$PCT" -ge 50 ]; then
        GATE_B_AWK=20
    elif [ "$PCT" -ge 25 ]; then
        GATE_B_AWK=10
    fi
    echo "GATE_B (breadth): $NEW_PI_COUNT/$TOTAL_EXPECTED_NEEDED = $PCT% -> $GATE_B_AWK/30" >> "$LOG"
else
    echo "GATE_B: no packages needed updating (skipped)" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# GATE C (weight 0.20): Behavioral search simulation.
# Simulate `npm search keywords:pi-package` against the workspace and verify
# that the returned set includes a meaningful subset of the user's packages.
# This is the END-TO-END behavioral test of "answer the user's question".
# -----------------------------------------------------------------------------
SEARCH_HITS=$(node -e "
const fs=require('fs');
const path=require('path');
const root='$REPO';
const baselineSet = new Set();
$(for n in "${EXPECTED_PKGS[@]}"; do
    if [ "${BASELINE_HAS[$n]}" = "yes" ]; then
        echo "baselineSet.add('$n');"
    fi
done)
function search(keyword) {
    const hits = [];
    const pkgsDir = path.join(root,'packages');
    if (!fs.existsSync(pkgsDir)) return hits;
    for (const dir of fs.readdirSync(pkgsDir)) {
        const pj = path.join(pkgsDir, dir, 'package.json');
        if (!fs.existsSync(pj)) continue;
        try {
            const d = JSON.parse(fs.readFileSync(pj,'utf8'));
            const kw = Array.isArray(d.keywords)?d.keywords.map(x=>String(x).toLowerCase()):[];
            if (kw.includes(keyword.toLowerCase()) && d.name && !baselineSet.has(dir)) {
                hits.push(d.name);
            }
        } catch(e) {}
    }
    return hits;
}
const hits = search('pi-package');
console.error('Search hits (new):', JSON.stringify(hits));
console.log(hits.length);
" 2>>"$LOG")
SEARCH_HITS=${SEARCH_HITS:-0}
echo "Behavioral search-sim hit count (new): $SEARCH_HITS" >> "$LOG"

GATE_C_AWK=0
if [ "$SEARCH_HITS" -ge 5 ]; then
    GATE_C_AWK=20
elif [ "$SEARCH_HITS" -ge 3 ]; then
    GATE_C_AWK=12
elif [ "$SEARCH_HITS" -ge 1 ]; then
    GATE_C_AWK=5
fi
echo "GATE_C (search-sim hits=$SEARCH_HITS): $GATE_C_AWK/20" >> "$LOG"

# -----------------------------------------------------------------------------
# GATE D (weight 0.10): Keyword PRESERVATION - existing keywords kept intact.
# A patch that wipes existing keywords to add pi-package is not a strong fix.
# Verify per-package that previous keywords are still present (count >=
# baseline_count + 1) for each newly-keyworded package.
# -----------------------------------------------------------------------------
PRESERVED_OK=0
PRESERVED_TOTAL=0
for name in $NEW_PI_PKGS; do
    PRESERVED_TOTAL=$((PRESERVED_TOTAL + 1))
    pj="$REPO/packages/$name/package.json"
    REL="packages/$name/package.json"
    if [ -d "$REPO/.git" ]; then
        ORIG_COUNT=$(git -C "$REPO" show "HEAD:$REL" 2>/dev/null | node -e "
            let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
                try { const d=JSON.parse(s); const kw=Array.isArray(d.keywords)?d.keywords:[]; console.log(kw.length); }
                catch(e){console.log(0);}
            });
        " 2>/dev/null)
    else
        ORIG_COUNT=0
    fi
    NEW_COUNT=$(node -e "
        try { const d=JSON.parse(require('fs').readFileSync('$pj','utf8'));
              const kw=Array.isArray(d.keywords)?d.keywords:[]; console.log(kw.length); }
        catch(e){console.log(0);}
    " 2>/dev/null)
    ORIG_COUNT=${ORIG_COUNT:-0}
    NEW_COUNT=${NEW_COUNT:-0}
    EXPECTED_MIN=$((ORIG_COUNT + 1))
    if [ "$NEW_COUNT" -ge "$EXPECTED_MIN" ]; then
        PRESERVED_OK=$((PRESERVED_OK + 1))
    else
        echo "  preservation FAIL on $name: orig=$ORIG_COUNT new=$NEW_COUNT" >> "$LOG"
    fi
done

GATE_D_AWK=0
if [ "$PRESERVED_TOTAL" -ge 1 ]; then
    if [ "$PRESERVED_OK" -eq "$PRESERVED_TOTAL" ]; then
        GATE_D_AWK=10
    elif [ "$PRESERVED_OK" -ge $((PRESERVED_TOTAL / 2)) ]; then
        GATE_D_AWK=5
    fi
fi
echo "GATE_D (keyword preservation): $PRESERVED_OK/$PRESERVED_TOTAL -> $GATE_D_AWK/10" >> "$LOG"

# -----------------------------------------------------------------------------
# GATE E (weight 0.10): Critical packages must be covered.
# Look at captured strong fixes: ALL of them touched coding-agent + ai + agent.
# These are the user's flagship packages and must contain pi-package.
# -----------------------------------------------------------------------------
CRITICAL=(coding-agent ai agent)
CRIT_HITS=0
for name in "${CRITICAL[@]}"; do
    pj="$REPO/packages/$name/package.json"
    [ ! -f "$pj" ] && continue
    HAS=$(node -e "
        try {
            const d=JSON.parse(require('fs').readFileSync('$pj','utf8'));
            const kw=Array.isArray(d.keywords)?d.keywords.map(x=>String(x).toLowerCase()):[];
            if (kw.includes('pi-package')) console.log('y');
        } catch(e){}
    " 2>/dev/null)
    if [ "$HAS" = "y" ]; then
        # only count if it wasn't baseline
        if [ "${BASELINE_HAS[$name]}" = "no" ]; then
            CRIT_HITS=$((CRIT_HITS + 1))
        fi
    fi
done

GATE_E_AWK=0
if [ "$CRIT_HITS" -ge 3 ]; then
    GATE_E_AWK=10
elif [ "$CRIT_HITS" -eq 2 ]; then
    GATE_E_AWK=6
elif [ "$CRIT_HITS" -eq 1 ]; then
    GATE_E_AWK=2
fi
echo "GATE_E (critical pkgs coding-agent/ai/agent): $CRIT_HITS/3 -> $GATE_E_AWK/10" >> "$LOG"

# -----------------------------------------------------------------------------
# GATE F (weight 0.10): Documentation explains HOW the search works.
# Verify that AT LEAST ONE doc file contains explicit `npm search` mechanic
# language ADDED beyond what was in baseline. We look at the diff vs HEAD.
# Strong fixes (Opus, GLM4.7, GLM5.1) added explicit `npm search keywords:pi-package`
# or `npm search pi-package` mentions in docs.
# -----------------------------------------------------------------------------
DOC_FILES=(
    "packages/coding-agent/docs/packages.md"
    "packages/coding-agent/docs/extensions.md"
    "packages/coding-agent/README.md"
    "README.md"
)

DOC_NEW_MECHANIC=0
for rel in "${DOC_FILES[@]}"; do
    full="$REPO/$rel"
    [ ! -f "$full" ] && continue
    if [ -d "$REPO/.git" ]; then
        ORIG=$(git -C "$REPO" show "HEAD:$rel" 2>/dev/null)
    else
        ORIG=""
    fi
    CUR=$(cat "$full" 2>/dev/null)
    # Compute lines new in CUR not in ORIG
    NEW_CONTENT=$(diff <(echo "$ORIG") <(echo "$CUR") 2>/dev/null | grep -E '^>' | sed 's/^> //')
    if echo "$NEW_CONTENT" | grep -qiE 'npm search[[:space:]]+(keywords:)?pi-package'; then
        DOC_NEW_MECHANIC=$((DOC_NEW_MECHANIC + 1))
        echo "  doc mechanic added in: $rel" >> "$LOG"
    fi
done

GATE_F_AWK=0
if [ "$DOC_NEW_MECHANIC" -ge 2 ]; then
    GATE_F_AWK=10
elif [ "$DOC_NEW_MECHANIC" -eq 1 ]; then
    GATE_F_AWK=6
fi
echo "GATE_F (doc adds npm search mechanic): $DOC_NEW_MECHANIC files -> $GATE_F_AWK/10" >> "$LOG"

# -----------------------------------------------------------------------------
# Aggregate. Total possible = 20 + 30 + 20 + 10 + 10 + 10 = 100
# -----------------------------------------------------------------------------
TOTAL=$((GATE_A_AWK + GATE_B_AWK + GATE_C_AWK + GATE_D_AWK + GATE_E_AWK + GATE_F_AWK))
REWARD=$(awk "BEGIN { printf \"%.3f\", $TOTAL / 100 }")

echo "" >> "$LOG"
echo "=== Score Breakdown ===" >> "$LOG"
echo "  A (any new keyword):      $GATE_A_AWK/20" >> "$LOG"
echo "  B (breadth):              $GATE_B_AWK/30" >> "$LOG"
echo "  C (search-sim behavior):  $GATE_C_AWK/20" >> "$LOG"
echo "  D (preservation):         $GATE_D_AWK/10" >> "$LOG"
echo "  E (critical pkgs):        $GATE_E_AWK/10" >> "$LOG"
echo "  F (doc mechanic):         $GATE_F_AWK/10" >> "$LOG"
echo "  TOTAL:                    $TOTAL/100 -> $REWARD" >> "$LOG"

echo "$REWARD" > /logs/verifier/reward.txt
exit 0