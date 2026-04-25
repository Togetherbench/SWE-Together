#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono "pi-package" keyword discoverability task
# =============================================================================
# Task interpretation: user wants to know how to search npm for packages by
# keyword. The good fix is to:
#   1. Add the "pi-package" keyword to the workspace's own package.json files
#      so they are discoverable via `npm search keywords:pi-package`.
#   2. Document the keyword convention in user-facing docs (README/docs).
#
# Stronger fixes will:
#   - Add the keyword to MANY packages (not just one).
#   - Mention how to search (npm search / npmjs.com URL) in docs.
#
# Weaker fixes will:
#   - Touch only docs OR only package.json.
#   - Add the keyword in only one place.
# =============================================================================

REPO="/workspace/pi-mono"
LOG="/logs/verifier/details.log"
mkdir -p /logs/verifier
echo "=== Verifier Start ===" > "$LOG"

REWARD_CENTS=0

if [ ! -d "$REPO" ]; then
    echo "FATAL: $REPO not found" >> "$LOG"
    echo "0.0" > /logs/verifier/reward.txt
    cat "$LOG"
    echo "REWARD: 0.0"
    exit 0
fi

cd "$REPO"

# Make sure node is reachable
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
    for cand in /usr/local/bin/node /usr/bin/node /root/.nvm/versions/node/*/bin/node; do
        if [ -x "$cand" ]; then
            export PATH="$(dirname $cand):$PATH"
            break
        fi
    done
fi

# Enumerate workspace package.json files (under packages/* and root)
PKG_JSONS=()
for pj in "$REPO"/packages/*/package.json "$REPO"/package.json; do
    [ -f "$pj" ] && PKG_JSONS+=("$pj")
done
TOTAL_PKGS=${#PKG_JSONS[@]}
echo "Found $TOTAL_PKGS package.json files in workspace" >> "$LOG"

# -----------------------------------------------------------------------------
# Gate 1 (P2P regression, weight 0.15): All package.json files remain valid JSON
# AND retain their "name" field. Guards against accidental corruption.
# -----------------------------------------------------------------------------
GATE1_PASS=true
for pj in "${PKG_JSONS[@]}"; do
    OK=$(node -e "
        try {
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            if (typeof d.name === 'string' && d.name.length > 0) console.log('ok');
        } catch(e) {}
    " 2>/dev/null)
    if [ "$OK" != "ok" ]; then
        GATE1_PASS=false
        echo "GATE1 FAIL: $pj invalid or missing name" >> "$LOG"
    fi
done

if [ "$GATE1_PASS" = true ]; then
    REWARD_CENTS=$((REWARD_CENTS + 15))
    echo "GATE1 PASS (P2P, +0.15): all package.json valid with name" >> "$LOG"
else
    echo "GATE1 FAIL (P2P)" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Gate 2 (F2P behavioral, weight up to 0.30): "pi-package" keyword present in
# package.json keywords arrays. Verified by parsing JSON and asserting that
# the keyword string appears in the keywords array.
#
# Tiered: 0 -> 0pts, 1 -> 10pts, 2-3 -> 20pts, 4+ -> 30pts.
# Rewards breadth, since the user said "I have a few packages".
# -----------------------------------------------------------------------------
PI_PKG_COUNT=0
PI_PKG_LIST=""
for pj in "${PKG_JSONS[@]}"; do
    HAS_KW=$(node -e "
        try {
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            const kw = Array.isArray(d.keywords) ? d.keywords : [];
            if (kw.map(x => String(x).toLowerCase()).includes('pi-package')) {
                console.log('yes');
            }
        } catch(e) {}
    " 2>/dev/null)
    if [ "$HAS_KW" = "yes" ]; then
        PI_PKG_COUNT=$((PI_PKG_COUNT + 1))
        PI_PKG_LIST="$PI_PKG_LIST $(basename $(dirname $pj))"
    fi
done

echo "Packages with pi-package keyword: $PI_PKG_COUNT ($PI_PKG_LIST)" >> "$LOG"

GATE2_AWARD=0
if [ "$PI_PKG_COUNT" -ge 4 ]; then
    GATE2_AWARD=30
elif [ "$PI_PKG_COUNT" -ge 2 ]; then
    GATE2_AWARD=20
elif [ "$PI_PKG_COUNT" -ge 1 ]; then
    GATE2_AWARD=10
fi
REWARD_CENTS=$((REWARD_CENTS + GATE2_AWARD))
echo "GATE2 (F2P, +0.$(printf '%02d' $GATE2_AWARD)): pi-package keyword in $PI_PKG_COUNT package(s)" >> "$LOG"

# -----------------------------------------------------------------------------
# Gate 3 (F2P behavioral simulation, weight 0.20):
# Simulate `npm search keywords:pi-package` by scanning the workspace and
# emitting the same matching list that npm registry would produce for the
# user's question. We require >=2 distinct package NAMES to be returned.
# This is a behavioral end-to-end check: invoking the simulated search must
# return real results.
# -----------------------------------------------------------------------------
SEARCH_RESULTS=$(node -e "
const fs = require('fs');
const path = require('path');
const root = '$REPO';
const dirs = fs.readdirSync(path.join(root,'packages'), {withFileTypes:true})
    .filter(d => d.isDirectory()).map(d => path.join(root,'packages',d.name));
dirs.push(root);
const out = [];
for (const dir of dirs) {
    const pj = path.join(dir,'package.json');
    if (!fs.existsSync(pj)) continue;
    try {
        const d = JSON.parse(fs.readFileSync(pj,'utf8'));
        const kw = Array.isArray(d.keywords) ? d.keywords.map(x=>String(x).toLowerCase()) : [];
        if (kw.includes('pi-package') && d.name) {
            out.push(d.name);
        }
    } catch(e) {}
}
console.log(JSON.stringify(out));
" 2>/dev/null)

NUM_RESULTS=$(echo "$SEARCH_RESULTS" | node -e "
let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
    try { const a = JSON.parse(s.trim()); console.log(a.length); } catch(e){console.log(0);}
});" 2>/dev/null)
NUM_RESULTS=${NUM_RESULTS:-0}

echo "Simulated 'npm search keywords:pi-package' returned $NUM_RESULTS package(s): $SEARCH_RESULTS" >> "$LOG"

GATE3_AWARD=0
if [ "$NUM_RESULTS" -ge 4 ]; then
    GATE3_AWARD=20
elif [ "$NUM_RESULTS" -ge 2 ]; then
    GATE3_AWARD=12
elif [ "$NUM_RESULTS" -ge 1 ]; then
    GATE3_AWARD=5
fi
REWARD_CENTS=$((REWARD_CENTS + GATE3_AWARD))
echo "GATE3 (F2P search-sim, +0.$(printf '%02d' $GATE3_AWARD))" >> "$LOG"

# -----------------------------------------------------------------------------
# Gate 4 (F2P documentation quality, weight up to 0.20):
# Documentation should explain how to USE/SEARCH the keyword, not merely
# include it as a substring. We give partial credit:
#   - 8 pts: any .md file (outside node_modules) mentions "pi-package" as a
#            keyword concept (excluding the pre-existing "other-pi-package"
#            example which exists at baseline).
#   - +12 pts: documentation mentions search mechanics — one of:
#            "npm search", "keywords:pi-package", "npmjs.com/search",
#            or text describing discoverability with the keyword.
# -----------------------------------------------------------------------------
GATE4_AWARD=0

DOC_FILES=$(find "$REPO" -name '*.md' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)

# Count "real" pi-package mentions (excluding baseline 'other-pi-package' refs)
REAL_DOC_LINES=0
SEARCH_DOC_HITS=0
for mdf in $DOC_FILES; do
    [ -f "$mdf" ] || continue
    HITS=$(node -e "
        const fs=require('fs');
        const c = fs.readFileSync('$mdf','utf8');
        const lines = c.split('\n');
        let real = 0;
        let search = 0;
        for (const l of lines) {
            const low = l.toLowerCase();
            // strip 'other-pi-package' occurrences before checking
            const stripped = low.replace(/other-pi-package/g,'');
            if (stripped.includes('pi-package')) {
                real++;
                if (low.includes('npm search') ||
                    low.includes('keywords:pi-package') ||
                    low.includes('keywords%3api-package') ||
                    low.includes('npmjs.com/search') ||
                    low.includes('discover') ||
                    low.includes('find') ||
                    low.includes('search')) {
                    search++;
                }
            }
        }
        console.log(real + ':' + search);
    " 2>/dev/null)
    R=$(echo "$HITS" | cut -d: -f1)
    S=$(echo "$HITS" | cut -d: -f2)
    R=${R:-0}; S=${S:-0}
    REAL_DOC_LINES=$((REAL_DOC_LINES + R))
    SEARCH_DOC_HITS=$((SEARCH_DOC_HITS + S))
done

echo "Doc lines mentioning pi-package (non-baseline): $REAL_DOC_LINES; with search context: $SEARCH_DOC_HITS" >> "$LOG"

# Compare against baseline (the unmodified repo already had some "pi-package"
# references in docs/READMEs, so we require an INCREASE in either total real
# mentions OR search-context mentions).
# Compute baseline by inspecting git HEAD versions of the same files.
BASELINE_REAL=0
BASELINE_SEARCH=0
for mdf in $DOC_FILES; do
    REL=${mdf#$REPO/}
    HITS=$(cd "$REPO" && git show HEAD:"$REL" 2>/dev/null | node -e "
        let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
            const lines=s.split('\n');
            let real=0,search=0;
            for(const l of lines){
                const low=l.toLowerCase();
                const stripped=low.replace(/other-pi-package/g,'');
                if(stripped.includes('pi-package')){
                    real++;
                    if(low.includes('npm search')||low.includes('keywords:pi-package')||
                       low.includes('keywords%3api-package')||low.includes('npmjs.com/search')||
                       low.includes('discover')||low.includes('find')||low.includes('search')){
                        search++;
                    }
                }
            }
            console.log(real+':'+search);
        });" 2>/dev/null)
    if [ -n "$HITS" ]; then
        BR=$(echo "$HITS" | cut -d: -f1)
        BS=$(echo "$HITS" | cut -d: -f2)
        BR=${BR:-0}; BS=${BS:-0}
        BASELINE_REAL=$((BASELINE_REAL + BR))
        BASELINE_SEARCH=$((BASELINE_SEARCH + BS))
    fi
done

echo "Baseline doc mentions: real=$BASELINE_REAL search=$BASELINE_SEARCH" >> "$LOG"

DELTA_REAL=$((REAL_DOC_LINES - BASELINE_REAL))
DELTA_SEARCH=$((SEARCH_DOC_HITS - BASELINE_SEARCH))

if [ "$DELTA_REAL" -ge 1 ] || [ "$REAL_DOC_LINES" -ge 1 -a "$BASELINE_REAL" -eq 0 ]; then
    GATE4_AWARD=$((GATE4_AWARD + 8))
fi
if [ "$DELTA_SEARCH" -ge 1 ]; then
    GATE4_AWARD=$((GATE4_AWARD + 12))
fi
# Cap at 20
[ "$GATE4_AWARD" -gt 20 ] && GATE4_AWARD=20
REWARD_CENTS=$((REWARD_CENTS + GATE4_AWARD))
echo "GATE4 (F2P docs, +0.$(printf '%02d' $GATE4_AWARD)) deltaReal=$DELTA_REAL deltaSearch=$DELTA_SEARCH" >> "$LOG"

# -----------------------------------------------------------------------------
# Gate 5 (F2P workspace integrity, weight 0.10):
# After modification, the workspace should still parse coherently:
# - Each modified package.json keywords array contains only strings.
# - No duplicate keys / no JSON5-only syntax.
# This is a real behavioral check (catches agents that hand-edit and break
# JSON formatting like trailing commas).
# -----------------------------------------------------------------------------
GATE5_PASS=true
for pj in "${PKG_JSONS[@]}"; do
    OK=$(node -e "
        try {
            const raw = require('fs').readFileSync('$pj','utf8');
            const d = JSON.parse(raw);
            const kw = d.keywords;
            if (kw !== undefined) {
                if (!Array.isArray(kw)) throw new Error('keywords not array');
                for (const k of kw) {
                    if (typeof k !== 'string') throw new Error('non-string keyword');
                }
                const set = new Set(kw);
                if (set.size !== kw.length) throw new Error('duplicate keyword');
            }
            // round-trip check
            JSON.stringify(d);
            console.log('ok');
        } catch(e) {
            console.error(e.message);
        }
    " 2>/dev/null)
    if [ "$OK" != "ok" ]; then
        GATE5_PASS=false
        echo "GATE5 FAIL: $pj integrity issue" >> "$LOG"
    fi
done

if [ "$GATE5_PASS" = true ]; then
    REWARD_CENTS=$((REWARD_CENTS + 10))
    echo "GATE5 PASS (F2P, +0.10): keywords arrays are clean strings, no dupes" >> "$LOG"
else
    echo "GATE5 FAIL (F2P)" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Gate 6 (F2P change evidence, weight 0.05):
# Some change must exist beyond initial state (committed/staged/unstaged).
# -----------------------------------------------------------------------------
GATE6_PASS=false
DIFF_STAT=$(git diff HEAD --stat 2>/dev/null)
STAGED=$(git diff --cached --stat 2>/dev/null)
COMMITS=$(git log --oneline 2>/dev/null | wc -l)
if [ -n "$DIFF_STAT" ] || [ -n "$STAGED" ] || [ "$COMMITS" -gt 1 ]; then
    GATE6_PASS=true
    REWARD_CENTS=$((REWARD_CENTS + 5))
    echo "GATE6 PASS (F2P, +0.05): repo modified" >> "$LOG"
else
    echo "GATE6 FAIL (F2P): no changes" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Compute final reward (cents -> 0.XX). Cap at 100.
# -----------------------------------------------------------------------------
[ "$REWARD_CENTS" -gt 100 ] && REWARD_CENTS=100

if [ "$REWARD_CENTS" -eq 100 ]; then
    REWARD="1.0"
elif [ "$REWARD_CENTS" -ge 10 ]; then
    REWARD="0.$(printf '%02d' $REWARD_CENTS)"
elif [ "$REWARD_CENTS" -gt 0 ]; then
    REWARD="0.0$REWARD_CENTS"
else
    REWARD="0.0"
fi

echo "" >> "$LOG"
echo "=== Score breakdown ===" >> "$LOG"
echo "Gate1 P2P json-valid:   $GATE1_PASS (weight 0.15)" >> "$LOG"
echo "Gate2 F2P kw-breadth:   $PI_PKG_COUNT pkgs (awarded 0.$(printf '%02d' $GATE2_AWARD), max 0.30)" >> "$LOG"
echo "Gate3 F2P search-sim:   $NUM_RESULTS results (awarded 0.$(printf '%02d' $GATE3_AWARD), max 0.20)" >> "$LOG"
echo "Gate4 F2P docs:         deltaReal=$DELTA_REAL deltaSearch=$DELTA_SEARCH (awarded 0.$(printf '%02d' $GATE4_AWARD), max 0.20)" >> "$LOG"
echo "Gate5 F2P integrity:    $GATE5_PASS (weight 0.10)" >> "$LOG"
echo "Gate6 F2P changes:      $GATE6_PASS (weight 0.05)" >> "$LOG"
echo "Total cents: $REWARD_CENTS / 100" >> "$LOG"
echo "Final Reward: $REWARD" >> "$LOG"

echo "$REWARD" > /logs/verifier/reward.txt
cat "$LOG"
echo ""
echo "REWARD: $REWARD"