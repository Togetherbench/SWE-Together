#!/bin/bash
# Verifier for PR review task (pi-mono PR #1292)
# PR #1292 adds skip logic for Python venv dirs in skill loader (skills.ts)
# Key issues: missing changelog, .venv redundancy with dotfile check,
# spaces vs tabs, could use existing ignore infrastructure
#
# Gate classification:
#   P2P = pass-to-pass (passes on unmodified base AND on correct fix)
#   F2P = fail-to-pass (fails on unmodified base, passes on correct fix)
#
# Execution gates (python3 -c) account for 95% of reward weight.
# Total weights: P2P=0.05, F2P=0.95
# Nop baseline: 0.05 (only P2P-1 passes)

set +e

REWARD="0.00"
add_reward() {
  REWARD=$(python3 -c "print(f'{$REWARD + $1:.2f}')")
}

echo "=== PR #1292 Review Verification ==="
echo ""

# ---------- P2P-1: Repository integrity (0.05) ----------
# Passes on unmodified base AND after correct fix.
# Guards against agent deleting or corrupting the repo.
if [ -d /workspace/pi-mono ] && [ -f /workspace/pi-mono/package.json ]; then
  echo "PASS [0.05]: P2P-1 - Repository structure intact"
  add_reward 0.05
else
  echo "FAIL [0.05]: P2P-1 - Repository missing or damaged"
fi

# ---------- F2P-1: Review file exists with substantive content (0.05) ----------
# Uses python3 execution gate
REVIEW=""
REVIEW_CHECK=$(python3 -c "
import os, sys
paths = ['/workspace/review.md', '/workspace/pi-mono/review.md']
for p in paths:
    if os.path.isfile(p):
        content = open(p).read()
        if len(content) > 100:
            print(p)
            sys.exit(0)
print('')
sys.exit(1)
" 2>&1)
REVIEW_RC=$?

if [ $REVIEW_RC -eq 0 ] && [ -n "$REVIEW_CHECK" ]; then
  REVIEW="$REVIEW_CHECK"
  echo "PASS [0.05]: F2P-1 - Review file exists at $REVIEW with substantive content"
  add_reward 0.05
else
  echo "FAIL [0.05]: F2P-1 - No review file with substantive content found"
  echo ""
  echo "=== Final Score: $REWARD ==="
  mkdir -p /logs/verifier
  echo "$REWARD" > /logs/verifier/reward.txt
  exit 0
fi

# ---------- F2P-2: Review structure - basic sections present (0.05) ----------
# Uses python3 execution gate. Accepts multiple valid formats:
#   "Good:", "## Good", "**Good**:", etc.
BASIC_STRUCT=$(python3 -c "
import re, sys

content = open(sys.argv[1]).read()
found = 0
total = 5

# Check for required sections in any reasonable format
for pattern in ['good', 'bad', 'ugly', 'changelog', 'change.?summary']:
    regex = r'^(?:[#*\s]*)?(' + pattern + r')[\s:*]'
    if re.search(regex, content, re.MULTILINE | re.IGNORECASE):
        found += 1

# Bonus: Tests or Questions section
if re.search(r'^(?:[#*\s]*)?(tests|questions|assumptions)[\s:*]', content, re.MULTILINE | re.IGNORECASE):
    found += 1

# Need at least 4 of 5 required sections
if found >= 4:
    print('0.05')
else:
    print('0.00')
" "$REVIEW" 2>&1)

if [ "$BASIC_STRUCT" = "0.05" ]; then
  echo "PASS [0.05]: F2P-2 - Review has required sections"
  add_reward 0.05
else
  echo "FAIL [0.05]: F2P-2 - Review missing required sections"
fi

# ---------- F2P-3: Precise instruction-following format (0.15) ----------
# Uses python3 execution gate. The instruction explicitly specifies:
#   "Good:\n- ...\nBad:\n- ...\nUgly:\n- ..."
# NOT markdown headers like "## Good" or "**Good**".
# Tests whether agent follows the specified output format precisely.
FORMAT_SCORE=$(python3 -c "
import re, sys

content = open(sys.argv[1]).read()
score = 0.0

# Instruction specifies these exact section headers at line start
precise_sections = {
    r'^Good:': 0.03,
    r'^Bad:': 0.03,
    r'^Ugly:': 0.02,
    r'^Changelog:': 0.02,
    r'^Change [Ss]ummary:': 0.02,
}

for pattern, weight in precise_sections.items():
    if re.search(pattern, content, re.MULTILINE):
        score += weight

# Questions or Assumptions or Tests section in precise format
if re.search(r'^(Questions|Tests|Assumptions)', content, re.MULTILINE):
    score += 0.03

print(f'{score:.2f}')
" "$REVIEW" 2>&1)

if [ -n "$FORMAT_SCORE" ] && [ "$FORMAT_SCORE" != "0.00" ]; then
  echo "PASS [$FORMAT_SCORE/0.15]: F2P-3 - Precise instruction format (partial credit)"
  add_reward "$FORMAT_SCORE"
else
  echo "FAIL [0.15]: F2P-3 - Does not follow instruction output format precisely"
fi

# ---------- F2P-4: Content quality - discusses actual PR changes (0.10) ----------
# Uses python3 execution gate
QUALITY_SCORE=$(python3 -c "
import re, sys

content = open(sys.argv[1]).read()
lower = content.lower()
score = 0.0

# Mentions PR 1292 (0.02)
if '1292' in lower:
    score += 0.02

# Discusses actual code changes: skill loader, venv, pycache (0.03)
change_terms = ['skill', 'venv', '__pycache__', 'pycache', 'virtual env',
                'site-packages', 'site_packages']
if any(t in lower for t in change_terms):
    score += 0.03

# Identifies missing changelog entry (0.03)
changelog_patterns = [
    r'(missing|no|absent|lack).{0,40}changelog',
    r'changelog.{0,40}(missing|required|needed|absent|add)',
    r'changelog.{0,40}entry.{0,40}(missing|required|needed|absent)',
    r'no.{0,20}entry.{0,20}(exist|found)',
]
if any(re.search(p, lower) for p in changelog_patterns):
    score += 0.03

# Mentions tests are missing or not added (0.02)
test_patterns = [
    r'(no|missing|lack|without|absent).{0,20}test',
    r'test.{0,25}(miss|lack|absent|not)',
    r'no.{0,15}unit.{0,10}test',
]
if any(re.search(p, lower) for p in test_patterns):
    score += 0.02

print(f'{score:.2f}')
" "$REVIEW" 2>&1)

if [ -n "$QUALITY_SCORE" ] && [ "$QUALITY_SCORE" != "0.00" ]; then
  echo "PASS [$QUALITY_SCORE/0.10]: F2P-4 - Content quality (partial credit)"
  add_reward "$QUALITY_SCORE"
else
  echo "FAIL [0.10]: F2P-4 - Review does not discuss PR changes"
fi

# ---------- F2P-5: Deep analysis insights (0.30) ----------
# Uses python3 execution gate - tests for non-trivial analytical insights
# that distinguish strong from weak reviewers.
# The .venv redundancy insight is the key discriminator: it requires understanding
# the existing startsWith(".") guard in the code and recognizing .venv is caught by it.
DEEP_SCORE=$(python3 -c "
import re, sys

content = open(sys.argv[1]).read()
score = 0.0

# Insight 1: .venv redundancy with dotfile/startsWith check (0.20)
# The specific insight: .venv starts with '.' and entry.name.startsWith('.')
# already catches it, making the explicit .venv check redundant.
has_dot_mechanism = bool(re.search(
    r'startsWith.{0,25}[\"\x27(]\\\\?\.'
    r'|starts?.with.{0,25}[\"\x27(]\\\\?\.'
    r'|dot.?file|dot.?prefix|dot.?dir'
    r'|entry\.name.*\.'
    r'|names?\s+start.{0,20}(with|by)\s+[\"\x27.]'
    r'|begins?\s+with\s+[a-z\s]*dot'
    r'|leading\s+dot'
    r'|hidden.{0,20}(director|folder|file)',
    content, re.IGNORECASE))

has_venv_redundancy = bool(re.search(
    r'\.venv.{0,100}(redundant|already|unnecessar|superflu|overlap|duplicat|covered|caught|handled|filtered|excluded|skipped)'
    r'|(redundant|already|unnecessar|superflu|overlap|duplicat|covered).{0,100}\.venv',
    content, re.IGNORECASE))

if has_dot_mechanism and has_venv_redundancy:
    score += 0.20
elif has_venv_redundancy:
    score += 0.10  # partial: noted redundancy without explaining mechanism

# Insight 2: Formatting/indentation inconsistency - tabs vs spaces (0.05)
if re.search(
    r'space.{0,60}tab|tab.{0,60}space'
    r'|indent.{0,40}(inconsist|mismatch|mixed|wrong)'
    r'|whitespace.{0,40}(inconsist|mismatch|mixed)'
    r'|uses?\s.{0,40}spaces?\s.{0,40}(but|while|instead|whereas|rather).{0,50}tabs?'
    r'|format.{0,30}(inconsist|issue|problem)',
    content, re.IGNORECASE):
    score += 0.05

# Insight 3: Suggests using existing ignore infrastructure (0.05)
if re.search(
    r'ignore.{0,50}(package|infra|librar|existing|already|module|util)'
    r'|existing.{0,50}(ignore|infra|mechanism)'
    r'|package.manager.{0,50}(ignore|already|existing|has|uses)'
    r'|hardcod.{0,50}(vs|instead|rather).{0,50}(ignore|gitignore|pattern)'
    r'|\.gitignore.{0,40}(pars|handl|support|integrat|already|reuse|leverag)'
    r'|(reuse|leverag|utiliz).{0,50}(ignore|existing|infrastructure)',
    content, re.IGNORECASE):
    score += 0.05

print(f'{score:.2f}')
" "$REVIEW" 2>&1)

if [ -n "$DEEP_SCORE" ] && [ "$DEEP_SCORE" != "0.00" ]; then
  echo "PASS [$DEEP_SCORE/0.30]: F2P-5 - Deep analysis (partial credit)"
  add_reward "$DEEP_SCORE"
else
  echo "FAIL [0.30]: F2P-5 - No deep analysis insights found"
fi

# ---------- F2P-6: CHANGELOG.md modified with relevant entry (0.20) ----------
# Uses python3 + git execution gate
CHANGELOG_SCORE=$(python3 -c "
import subprocess, re, sys

result = subprocess.run(
    ['git', 'diff', '--', 'packages/*/CHANGELOG.md'],
    capture_output=True, text=True, cwd='/workspace/pi-mono'
)
diff = result.stdout

if not diff:
    print('0.00')
    sys.exit(0)

score = 0.0
lower = diff.lower()

# Base credit: CHANGELOG.md was modified at all (0.08)
score += 0.08

# Relevant content: mentions PR or its changes (0.07)
relevant_terms = ['skill', 'venv', '1292', 'ignore', 'loader', 'pycache',
                  'virtual', 'python', 'directory', 'filter']
if any(t in lower for t in relevant_terms):
    score += 0.07

# Proper attribution format for external PR (0.05)
if re.search(r'1292.*@?jverkoey|jverkoey.*1292|\[#1292\]|pull/1292', diff, re.IGNORECASE):
    score += 0.05

print(f'{score:.2f}')
" 2>&1)

if [ -n "$CHANGELOG_SCORE" ] && [ "$CHANGELOG_SCORE" != "0.00" ]; then
  echo "PASS [$CHANGELOG_SCORE/0.20]: F2P-6 - CHANGELOG.md modified (partial credit)"
  add_reward "$CHANGELOG_SCORE"
else
  echo "FAIL [0.20]: F2P-6 - CHANGELOG.md not modified"
fi

# ---------- F2P-7: Mentions PR author/contributor (0.10) ----------
# Uses python3 execution gate
AUTHOR_SCORE=$(python3 -c "
import sys

content = open(sys.argv[1]).read()
lower = content.lower()
score = 0.0

# Mentions the actual PR author (jverkoey) or acknowledges external contribution
if 'jverkoey' in lower:
    score += 0.10
elif any(t in lower for t in ['contributor', 'external', 'author', 'community']):
    score += 0.05

print(f'{score:.2f}')
" "$REVIEW" 2>&1)

if [ -n "$AUTHOR_SCORE" ] && [ "$AUTHOR_SCORE" != "0.00" ]; then
  echo "PASS [$AUTHOR_SCORE/0.10]: F2P-7 - Mentions PR author/contributor"
  add_reward "$AUTHOR_SCORE"
else
  echo "FAIL [0.10]: F2P-7 - Does not mention PR author"
fi

echo ""
echo "=== Final Score: $REWARD ==="
mkdir -p /logs/verifier
echo "$REWARD" > /logs/verifier/reward.txt
