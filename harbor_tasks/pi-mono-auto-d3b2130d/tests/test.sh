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

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
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

# Enumerate workspace package.json files
PKG_JSONS=()
for pj in "$REPO"/packages/*/package.json "$REPO"/package.json; do
    [ -f "$pj" ] && PKG_JSONS+=("$pj")
done
echo "Found ${#PKG_JSONS[@]} package.json files" >> "$LOG"

# -----------------------------------------------------------------------------
# P2P GATE (gating only, no reward): all package.json remain valid + retain name
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

# -----------------------------------------------------------------------------
# Establish a BASELINE for which packages already had "pi-package" keyword
# in the original buggy state. We must subtract these from credit so that a
# no-op patch scores 0.0.
# -----------------------------------------------------------------------------
# Inspection of the base repo: only "other-pi-package" appears as an example
# in docs and possibly one example package.json. We dynamically detect any
# baseline package.json that already had the keyword by checking git, falling
# back to a hard list if git unavailable.
BASELINE_KW_PKGS=""
if [ -d "$REPO/.git" ] && command -v git >/dev/null 2>&1; then
    cd "$REPO"
    for pj in "${PKG_JSONS[@]}"; do
        REL="${pj#$REPO/}"
        ORIG=$(git show "HEAD:$REL" 2>/dev/null)
        if [ -n "$ORIG" ]; then
            HAS=$(echo "$ORIG" | node -e "
                let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{
                    try {
                        const d = JSON.parse(s);
                        const kw = Array.isArray(d.keywords) ? d.keywords.map(x=>String(x).toLowerCase()) : [];
                        if (kw.includes('pi-package')) console.log('yes');
                    } catch(e) {}
                });
            " 2>/dev/null)
            if [ "$HAS" = "yes" ]; then
                BASELINE_KW_PKGS="$BASELINE_KW_PKGS $REL"
            fi
        fi
    done
fi
echo "Baseline packages with pi-package keyword: [$BASELINE_KW_PKGS ]" >> "$LOG"

# Helper: count packages that NEWLY have pi-package (not in baseline)
NEW_PI_COUNT=0
for pj in "${PKG_JSONS[@]}"; do
    REL="${pj#$REPO/}"
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
        # was it in baseline?
        case " $BASELINE_KW_PKGS " in
            *" $REL "*) ;;  # baseline, no credit
            *) NEW_PI_COUNT=$((NEW_PI_COUNT + 1)) ;;
        esac
    fi
done
echo "Newly-added pi-package keyword packages: $NEW_PI_COUNT" >> "$LOG"

# -----------------------------------------------------------------------------
# F2P GATE A (weight 0.45): breadth of keyword addition (NEW additions only).
# Tiered:
#   0 newly added -> 0.00
#   1            -> 0.10
#   2-3          -> 0.25
#   4+           -> 0.45
# On a no-op patch NEW_PI_COUNT == 0 -> 0.0.
# -----------------------------------------------------------------------------
GATE_A=0
if [ "$NEW_PI_COUNT" -ge 4 ]; then
    GATE_A=45
elif [ "$NEW_PI_COUNT" -ge 2 ]; then
    GATE_A=25
elif [ "$NEW_PI_COUNT" -ge 1 ]; then
    GATE_A=10
fi
echo "GATE_A (breadth, NEW additions=$NEW_PI_COUNT): +0.$(printf '%02d' $GATE_A)" >> "$LOG"

# -----------------------------------------------------------------------------
# F2P GATE B (weight 0.30): simulated `npm search keywords:pi-package` against
# the workspace must return >= 2 packages that were NOT in baseline. This is a
# behavioral end-to-end check that the user's question is answered: searching
# the user's own packages by keyword yields actual results.
# -----------------------------------------------------------------------------
SEARCH_NEW_COUNT=$(node -e "
const fs=require('fs');
const path=require('path');
const root='$REPO';
const baseline = new Set(('$BASELINE_KW_PKGS'.trim().split(/\s+/).filter(Boolean)));
const dirs = fs.existsSync(path.join(root,'packages'))
  ? fs.readdirSync(path.join(root,'packages'),{withFileTypes:true}).filter(d=>d.isDirectory()).map(d=>path.join(root,'packages',d.name))
  : [];
dirs.push(root);
let newCount = 0;
const names = [];
for (const dir of dirs) {
    const pj = path.join(dir,'package.json');
    if (!fs.existsSync(pj)) continue;
    const rel = pj.substring(root.length+1);
    try {
        const d = JSON.parse(fs.readFileSync(pj,'utf8'));
        const kw = Array.isArray(d.keywords)?d.keywords.map(x=>String(x).toLowerCase()):[];
        if (kw.includes('pi-package') && d.name && !baseline.has(rel)) {
            newCount++;
            names.push(d.name);
        }
    } catch(e) {}
}
console.error('Search-new names:', JSON.stringify(names));
console.log(newCount);
" 2>>"$LOG")
SEARCH_NEW_COUNT=${SEARCH_NEW_COUNT:-0}
echo "Simulated search NEW results: $SEARCH_NEW_COUNT" >> "$LOG"

GATE_B=0
if [ "$SEARCH_NEW_COUNT" -ge 4 ]; then
    GATE_B=30
elif [ "$SEARCH_NEW_COUNT" -ge 2 ]; then
    GATE_B=20
elif [ "$SEARCH_NEW_COUNT" -ge 1 ]; then
    GATE_B=8
fi
echo "GATE_B (search-sim NEW=$SEARCH_NEW_COUNT): +0.$(printf '%02d' $GATE_B)" >> "$LOG"

# -----------------------------------------------------------------------------
# F2P GATE C (weight 0.25): documentation explains HOW to search.
# We compare documentation to its baseline content. Reward only awarded when
# the diff introduces explicit search-mechanic language, not when content
# was already in the base.
#
# Mechanism: For each .md file, fetch original from git HEAD. Concatenate all
# *new* content (lines that didn't exist verbatim in baseline). Then check
# whether this newly-added content includes:
#   - any mention of "pi-package" (8 pts), AND
#   - search-mechanic language: "npm search", "keywords:pi-package",
#     "npmjs.com/search", "keywords%3api-package" (17 pts)
# On no-op patch, no new content -> 0 pts.
# -----------------------------------------------------------------------------
NEW_DOC_CONTENT=""
DOC_FILES=$(find "$REPO" -name '*.md' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)

if [ -d "$REPO/.git" ] && command -v git >/dev/null 2>&1; then
    cd "$REPO"
    for mdf in $DOC_FILES; do
        REL="${mdf#$REPO/}"
        ORIG=$(git show "HEAD:$REL" 2>/dev/null)
        CURRENT=$(cat "$mdf" 2>/dev/null)
        if [ "$ORIG" != "$CURRENT" ]; then
            # extract added lines using diff
            ADDED=$(diff <(echo "$ORIG") <(echo "$CURRENT") 2>/dev/null | grep '^>' | sed 's/^> //')
            NEW_DOC_CONTENT="$NEW_DOC_CONTENT
$ADDED"
        fi
    done
fi

NEW_DOC_LOWER=$(echo "$NEW_DOC_CONTENT" | tr '[:upper:]' '[:lower:]' | sed 's/other-pi-package//g')

GATE_C=0
HAS_KW_DOC=false
HAS_SEARCH_DOC=false
if echo "$NEW_DOC_LOWER" | grep -q 'pi-package'; then
    HAS_KW_DOC=true
fi
if echo "$NEW_DOC_LOWER" | grep -qE 'npm search|keywords:pi-package|keywords%3api-package|npmjs\.com/search'; then
    HAS_SEARCH_DOC=true
fi

if [ "$HAS_KW_DOC" = true ]; then
    GATE_C=$((GATE_C + 8))
fi
if [ "$HAS_SEARCH_DOC" = true ]; then
    GATE_C=$((GATE_C + 17))
fi
echo "GATE_C (doc kw-mention=$HAS_KW_DOC search-mention=$HAS_SEARCH_DOC): +0.$(printf '%02d' $GATE_C)" >> "$LOG"

# -----------------------------------------------------------------------------
# Compose final reward
# -----------------------------------------------------------------------------
TOTAL_CENTS=$((GATE_A + GATE_B + GATE_C))
# clamp to 100
if [ "$TOTAL_CENTS" -gt 100 ]; then
    TOTAL_CENTS=100
fi

REWARD=$(awk -v c="$TOTAL_CENTS" 'BEGIN{printf "%.2f", c/100}')
echo "TOTAL: $TOTAL_CENTS cents -> $REWARD" >> "$LOG"
echo "REWARD: $REWARD" >> "$LOG"

echo "$REWARD" > /logs/verifier/reward.txt