#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono keyword + documentation task
# =============================================================================
# The agent should:
# 1. Add "pi-package" keyword to package.json files
# 2. Document the "pi-package" keyword in .md files
# 3. Commit the changes
# =============================================================================

# Use integer cents to avoid bc dependency
REWARD_CENTS=0

REPO="/workspace/pi-mono"
LOG="/logs/verifier/details.log"
mkdir -p /logs/verifier
echo "=== Verifier Start ===" > "$LOG"

# -----------------------------------------------------------------------------
# Gate 1 (P2P, weight 0.10): All package.json files in packages/ are valid JSON
# This passes on unmodified base AND on correct fix — regression guard.
# -----------------------------------------------------------------------------
GATE1_PASS=true
for pj in "$REPO"/packages/*/package.json; do
    if [ -f "$pj" ]; then
        node -e "JSON.parse(require('fs').readFileSync('$pj','utf8'))" 2>/dev/null
        if [ $? -ne 0 ]; then
            GATE1_PASS=false
            echo "GATE1 FAIL: Invalid JSON in $pj" >> "$LOG"
        fi
    fi
done

if [ "$GATE1_PASS" = true ]; then
    REWARD_CENTS=$((REWARD_CENTS + 10))
    echo "GATE1 PASS (P2P): All package.json files are valid JSON (+0.10)" >> "$LOG"
else
    echo "GATE1 FAIL (P2P): Some package.json files have invalid JSON" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Gate 2 (F2P, weight 0.25): "pi-package" keyword in at least one package.json
# Behavioral check: uses node to parse JSON and verify keyword array contains
# "pi-package". Accepts any package.json under packages/ or root.
# Fails on base (no package has "pi-package" keyword).
# -----------------------------------------------------------------------------
GATE2_PASS=false
PI_PKG_COUNT=0
for pj in "$REPO"/packages/*/package.json "$REPO"/package.json; do
    if [ -f "$pj" ]; then
        HAS_KW=$(node -e "
            const d = JSON.parse(require('fs').readFileSync('$pj','utf8'));
            const kw = d.keywords || [];
            if (kw.includes('pi-package')) { console.log('yes'); }
        " 2>/dev/null)
        if [ "$HAS_KW" = "yes" ]; then
            PI_PKG_COUNT=$((PI_PKG_COUNT + 1))
        fi
    fi
done

if [ "$PI_PKG_COUNT" -ge 1 ]; then
    GATE2_PASS=true
    REWARD_CENTS=$((REWARD_CENTS + 25))
    echo "GATE2 PASS (F2P): Found 'pi-package' keyword in $PI_PKG_COUNT package.json file(s) (+0.25)" >> "$LOG"
else
    echo "GATE2 FAIL (F2P): No package.json contains 'pi-package' keyword" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Gate 3 (F2P, weight 0.25): "pi-package" documented in extensions.md or
# coding-agent README.md
# Behavioral check: uses node to read file and search for the string.
# Accepts any mention of "pi-package" as a keyword/search term in either file.
# Fails on base (neither file mentions "pi-package" as a discoverable keyword).
# Note: extensions.md has "other-pi-package" as an example dep name, but NOT
# as a keyword/search documentation. We check for "pi-package" as a standalone
# keyword concept, not just substring in a package name.
# -----------------------------------------------------------------------------
GATE3_PASS=false
EXT_MD="$REPO/packages/coding-agent/docs/extensions.md"
README_MD="$REPO/packages/coding-agent/README.md"

check_pi_package_doc() {
    local file="$1"
    if [ -f "$file" ]; then
        node -e "
            const fs = require('fs');
            const content = fs.readFileSync('$file', 'utf8');
            const lines = content.split('\n');
            const filtered = lines.filter(l =>
                !l.includes('other-pi-package') || l.includes('keyword')
            ).join('\n');
            if (filtered.match(/pi-package/i)) {
                console.log('yes');
            }
        " 2>/dev/null
    fi
}

DOC1=$(check_pi_package_doc "$EXT_MD")
DOC2=$(check_pi_package_doc "$README_MD")

if [ "$DOC1" = "yes" ] || [ "$DOC2" = "yes" ]; then
    GATE3_PASS=true
    REWARD_CENTS=$((REWARD_CENTS + 25))
    echo "GATE3 PASS (F2P): 'pi-package' documented in extensions.md or README.md (+0.25)" >> "$LOG"
else
    echo "GATE3 FAIL (F2P): 'pi-package' not documented in target .md files" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Gate 4 (F2P, weight 0.20): At least one .md file in the repo (outside
# node_modules) mentions "pi-package" as a keyword concept (not just as part
# of "other-pi-package" dependency example).
# Broader check than Gate 3 — accepts documentation in ANY .md file.
# Fails on base (no .md file documents "pi-package" as a keyword concept).
# -----------------------------------------------------------------------------
GATE4_PASS=false

cd "$REPO"
MD_WITH_PIPACKAGE=$(find "$REPO" -name '*.md' -not -path '*/node_modules/*' -exec grep -li 'pi-package' {} \; 2>/dev/null)

REAL_MENTIONS=0
for mdf in $MD_WITH_PIPACKAGE; do
    COUNT=$(node -e "
        const fs = require('fs');
        const content = fs.readFileSync('$mdf', 'utf8');
        const lines = content.split('\n');
        let count = 0;
        for (const l of lines) {
            if (l.includes('pi-package') && !l.match(/other-pi-package/)) {
                count++;
            }
        }
        console.log(count);
    " 2>/dev/null)
    if [ "$COUNT" -gt 0 ] 2>/dev/null; then
        REAL_MENTIONS=$((REAL_MENTIONS + COUNT))
    fi
done

if [ "$REAL_MENTIONS" -gt 0 ]; then
    GATE4_PASS=true
    REWARD_CENTS=$((REWARD_CENTS + 20))
    echo "GATE4 PASS (F2P): Found $REAL_MENTIONS line(s) documenting 'pi-package' in .md files (+0.20)" >> "$LOG"
else
    echo "GATE4 FAIL (F2P): No .md file documents 'pi-package' as a keyword" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Gate 5 (F2P, weight 0.20): Git working tree has changes (committed or staged
# or unstaged) beyond the initial checkout state.
# Fails on base (no changes in fresh checkout).
# -----------------------------------------------------------------------------
GATE5_PASS=false

cd "$REPO"
DIFF_STAT=$(git diff HEAD --stat 2>/dev/null)
COMMIT_COUNT=$(git log --oneline 2>/dev/null | wc -l)
STAGED=$(git diff --cached --stat 2>/dev/null)

if [ "$COMMIT_COUNT" -gt 1 ] || [ -n "$DIFF_STAT" ] || [ -n "$STAGED" ]; then
    GATE5_PASS=true
    REWARD_CENTS=$((REWARD_CENTS + 20))
    echo "GATE5 PASS (F2P): Git shows changes beyond initial state (+0.20)" >> "$LOG"
else
    echo "GATE5 FAIL (F2P): No git changes detected" >> "$LOG"
fi

# -----------------------------------------------------------------------------
# Write final reward
# -----------------------------------------------------------------------------
# Convert cents to decimal: e.g. 75 -> 0.75, 100 -> 1.0, 5 -> 0.05
if [ "$REWARD_CENTS" -eq 100 ]; then
    REWARD="1.0"
elif [ "$REWARD_CENTS" -ge 10 ]; then
    REWARD="0.${REWARD_CENTS}"
elif [ "$REWARD_CENTS" -gt 0 ]; then
    REWARD="0.0${REWARD_CENTS}"
else
    REWARD="0.0"
fi

echo "" >> "$LOG"
echo "=== Final Score: $REWARD ===" >> "$LOG"
echo "Gate1(P2P,0.10)=$GATE1_PASS Gate2(F2P,0.25)=$GATE2_PASS Gate3(F2P,0.25)=$GATE3_PASS Gate4(F2P,0.20)=$GATE4_PASS Gate5(F2P,0.20)=$GATE5_PASS" >> "$LOG"

echo "$REWARD" > /logs/verifier/reward.txt
cat "$LOG"
echo ""
echo "REWARD: $REWARD"
