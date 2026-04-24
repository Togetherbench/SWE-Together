#!/bin/bash
set +e

# Changelog Audit Verifier
# Task: Audit changelog entries for commits since v0.49.2 in pi-mono.
# Agent must find missing entries, add them with proper attribution format,
# and duplicate user-facing changes to coding-agent per cross-package rule.
#
# Gate Classification:
#   Gate 1 (P2P, 0.10): Changelog structure preserved
#   Gate 2 (F2P, 0.25): Missing tui changelog entries
#   Gate 3 (F2P, 0.15): Missing ai changelog entry
#   Gate 4 (F2P, 0.25): coding-agent entries + cross-package duplication
#   Gate 5 (F2P, 0.25): External PR attribution format

mkdir -p /logs/verifier
cd /workspace/pi-mono

###############################################################################
# Gate 1 (P2P, weight 0.10): Changelog files exist and have valid structure
# Passes on unmodified base AND on correct fix — guards against regression.
###############################################################################
GATE1=$(node -e "
const fs = require('fs');
const files = [
  'packages/ai/CHANGELOG.md',
  'packages/tui/CHANGELOG.md',
  'packages/coding-agent/CHANGELOG.md'
];
let ok = 0;
for (const f of files) {
  try {
    const c = fs.readFileSync(f, 'utf8');
    if (c.includes('## [Unreleased]') && c.includes('## [0.49.2]')) ok++;
  } catch(e) {}
}
console.log(ok === 3 ? 1 : 0);
" 2>/dev/null)

###############################################################################
# Gate 2 (F2P, weight 0.25): Missing tui changelog entries added
# Commits since v0.49.2 affecting tui that lack [Unreleased] entries:
#   - 698aea34: Alt+Delete hotkey (#878 by @Perlence)
#   - d37b5a52: Fuzzy matching improvements (#860 by @mitsuhiko)
#   - 565488fd: Viewport tracking / cursor positioning fix
# Each sub-check is worth ~0.083.
###############################################################################
GATE2=$(node -e "
const fs = require('fs');
const content = fs.readFileSync('packages/tui/CHANGELOG.md', 'utf8');
const unreleased = content.split('## [Unreleased]')[1]?.split(/## \[(?!Unreleased)/)[0] || '';
const lower = unreleased.toLowerCase();
let score = 0;
// Alt+Delete or PR #878
if (unreleased.includes('#878') || lower.includes('alt+delete') || lower.includes('alt-delete')) score++;
// Fuzzy matching or PR #860
if (unreleased.includes('#860') || lower.includes('fuzzy')) score++;
// Viewport tracking / cursor positioning / overlay
if (lower.includes('viewport') || lower.includes('cursor position') || lower.includes('overlay')) score++;
console.log(score);
" 2>/dev/null)

###############################################################################
# Gate 3 (F2P, weight 0.15): Missing ai changelog entry
# Commit 693112e3: feat(ai): add originator option to loginOpenAICodex
# The [Unreleased] section must mention 'originator'.
###############################################################################
GATE3=$(node -e "
const fs = require('fs');
const content = fs.readFileSync('packages/ai/CHANGELOG.md', 'utf8');
const unreleased = content.split('## [Unreleased]')[1]?.split(/## \[(?!Unreleased)/)[0] || '';
console.log(unreleased.toLowerCase().includes('originator') ? 1 : 0);
" 2>/dev/null)

###############################################################################
# Gate 4 (F2P, weight 0.25): coding-agent changelog completeness
# Checks:
#   a) PI_SHARE_VIEWER_URL / #889 entry added
#   b) Cross-package: 256color fallback / #869 duplicated
#   c) Cross-package: at least one tui entry (#878 / #860 / fuzzy / Alt+Delete)
# Each sub-check is worth ~0.083.
###############################################################################
GATE4=$(node -e "
const fs = require('fs');
const content = fs.readFileSync('packages/coding-agent/CHANGELOG.md', 'utf8');
const unreleased = content.split('## [Unreleased]')[1]?.split(/## \[(?!Unreleased)/)[0] || '';
const lower = unreleased.toLowerCase();
let score = 0;
// PI_SHARE_VIEWER_URL or #889
if (unreleased.includes('#889') || unreleased.includes('PI_SHARE_VIEWER_URL') || lower.includes('share viewer') || lower.includes('share_viewer')) score++;
// 256color fallback or #869
if (unreleased.includes('#869') || lower.includes('256color') || lower.includes('256-color') || lower.includes('256 color') || lower.includes('terminal.app')) score++;
// Cross-package tui entries
if (unreleased.includes('#878') || unreleased.includes('#860') || lower.includes('fuzzy') || lower.includes('alt+delete') || lower.includes('alt-delete')) score++;
console.log(score);
" 2>/dev/null)

###############################################################################
# Gate 5 (F2P, weight 0.25): External PR attributions in [Unreleased]
# The instruction requires: "Description ([#N](url) by [@user](url))"
# Checks that newly-added external PRs have 'by [@' attribution.
# Specifically checks PRs #855, #878, #860, #888 in tui, and #889 in coding-agent.
# These are all external PRs missing attribution in the base state.
###############################################################################
GATE5=$(node -e "
const fs = require('fs');
function getUnreleased(file) {
  const c = fs.readFileSync(file, 'utf8');
  return c.split('## [Unreleased]')[1]?.split(/## \[(?!Unreleased)/)[0] || '';
}
const tui = getUnreleased('packages/tui/CHANGELOG.md');
const ca = getUnreleased('packages/coding-agent/CHANGELOG.md');

function hasAttributedPR(text, prNum) {
  const lines = text.split('\n');
  for (const line of lines) {
    if (line.includes('#' + prNum) && line.includes('by [@')) return true;
  }
  return false;
}

let score = 0;
let total = 0;
// Check tui PRs
for (const pr of ['855', '878', '860', '888']) {
  // Only count if PR appears at all (entry was added)
  if (tui.includes('#' + pr)) {
    total++;
    if (hasAttributedPR(tui, pr)) score++;
  }
}
// Check coding-agent PRs
for (const pr of ['889', '881', '870', '876']) {
  if (ca.includes('#' + pr)) {
    total++;
    if (hasAttributedPR(ca, pr)) score++;
  }
}
// Output ratio: attributed / total entries that reference these PRs
if (total === 0) {
  console.log(0);
} else {
  console.log(Math.min(score / total, 1.0).toFixed(4));
}
" 2>/dev/null)

###############################################################################
# Compute final score
###############################################################################
REWARD=$(python3 -c "
g1 = float('${GATE1}' or '0')
g2 = float('${GATE2}' or '0')
g3 = float('${GATE3}' or '0')
g4 = float('${GATE4}' or '0')
g5 = float('${GATE5}' or '0')

score = 0.0

# Gate 1 (P2P): 0.10 if all 3 changelogs have valid structure
score += g1 * 0.10

# Gate 2 (F2P): 0.25 scaled by fraction of 3 missing tui entries found
score += (g2 / 3.0) * 0.25

# Gate 3 (F2P): 0.15 if originator entry added to ai changelog
score += g3 * 0.15

# Gate 4 (F2P): 0.25 scaled by fraction of 3 coding-agent checks
score += (g4 / 3.0) * 0.25

# Gate 5 (F2P): 0.25 scaled by attribution ratio
score += g5 * 0.25

# Clamp to [0, 1]
score = max(0.0, min(1.0, round(score, 4)))
print(score)
" 2>/dev/null)

echo "Gate1(P2P-structure)=$GATE1 Gate2(F2P-tui)=$GATE2/3 Gate3(F2P-ai)=$GATE3 Gate4(F2P-ca)=$GATE4/3 Gate5(F2P-attrib)=$GATE5"
echo "Reward: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt
