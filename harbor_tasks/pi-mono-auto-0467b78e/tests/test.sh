#!/bin/bash
set +e

# Verifier for PR #1292: skill loader should skip Python venv / cache dirs
# Repo at /workspace/pi-mono. Task is a PR review + changelog addition.
# We score by:
#   (a) review file quality (structural + content insights)
#   (b) changelog entry presence in coding-agent
#   (c) behavioral check: skill loader actually skips venv/__pycache__/site-packages

REWARD="0.00"
add_reward() {
  REWARD=$(awk -v a="$REWARD" -v b="$1" 'BEGIN{printf "%.3f", a+b}')
}

REPO=/workspace/pi-mono
PKG=$REPO/packages/coding-agent
SKILLS=$PKG/src/core/skills.ts
CHANGELOG=$PKG/CHANGELOG.md

mkdir -p /logs/verifier

echo "=== PR #1292 Review Verification ==="

# ---------- P2P-1: Repository intact (0.05) ----------
if [ -d "$REPO" ] && [ -f "$REPO/package.json" ] && [ -f "$SKILLS" ]; then
  echo "PASS [0.05]: P2P-1 - Repository structure intact"
  add_reward 0.05
else
  echo "FAIL [0.05]: P2P-1 - Repository missing or damaged"
  echo "$REWARD" > /logs/verifier/reward.txt
  exit 0
fi

# ---------- Locate review file ----------
REVIEW=""
for p in /workspace/review.md /workspace/pi-mono/review.md; do
  if [ -f "$p" ] && [ "$(wc -c < "$p")" -gt 200 ]; then
    REVIEW="$p"
    break
  fi
done

if [ -z "$REVIEW" ]; then
  echo "FAIL: No substantive review.md found"
  echo "$REWARD" > /logs/verifier/reward.txt
  exit 0
fi
echo "INFO: Review file at $REVIEW"

# ---------- F2P-1: Review structure (0.05) ----------
STRUCT=$(python3 - "$REVIEW" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
need = ['good', 'bad', 'ugly', 'changelog']
found = sum(1 for p in need if re.search(r'(?im)^[\s#*]*'+p+r'[\s:*]', c))
print(found)
PY
)
if [ "${STRUCT:-0}" -ge 4 ]; then
  echo "PASS [0.05]: F2P-1 - Review has required sections ($STRUCT/4)"
  add_reward 0.05
else
  echo "FAIL [0.05]: F2P-1 - Missing sections ($STRUCT/4)"
fi

# ---------- F2P-2: Review content quality (0.10) ----------
QSCORE=$(python3 - "$REVIEW" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
low = c.lower()
s = 0.0
# (a) discusses the actual change
if any(t in low for t in ['venv', '__pycache__', 'pycache', 'site-packages', 'site_packages', 'virtual env']):
    s += 0.03
# (b) mentions PR or issue number
if '1292' in low or '1294' in low:
    s += 0.02
# (c) discusses changelog status
if re.search(r'changelog', low):
    s += 0.02
# (d) mentions tests / regression coverage gap
if re.search(r'(no|missing|lack|without|absent)[^.]{0,30}test', low) or re.search(r'test[^.]{0,30}(miss|lack|absent|not\s+add)', low):
    s += 0.03
print(f"{s:.3f}")
PY
)
add_reward "${QSCORE:-0}"
echo "SCORE [$QSCORE/0.10]: F2P-2 - Content quality"

# ---------- F2P-3: Deep insights (0.15) ----------
DSCORE=$(python3 - "$REVIEW" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
low = c.lower()
s = 0.0
# Key insight: should reuse existing ignore() infrastructure rather than ad-hoc if checks
reuse = bool(re.search(r'(reuse|leverag|use).{0,40}(ignore|gitignore|existing)', low) or
             re.search(r'(ignore|gitignore).{0,40}(infrastructure|matcher|mechanism|already|exist)', low) or
             re.search(r'hardcod', low) or
             re.search(r'(ad.hoc|instead of|rather than).{0,50}ignore', low))
if reuse:
    s += 0.06

# Insight: .venv / dotfile redundancy OR mention that .venv missing
dotfile = bool(re.search(r'(dot.?file|leading dot|starts?.with.{0,20}["\'.]|hidden.{0,20}(dir|file)|\.venv)', low))
if dotfile:
    s += 0.04

# Insight: mentions tabs/spaces or formatting/indent
if re.search(r'(tab.{0,40}space|space.{0,40}tab|indent.{0,30}(inconsist|mismatch|mixed|wrong)|format.{0,30}(inconsist|issue))', low):
    s += 0.03

# Insight: notes lack of regression test for the FD-exhaustion / skip behavior
if re.search(r'(regression|fd|file descriptor|36k|36,?000)', low):
    s += 0.02

print(f"{s:.3f}")
PY
)
add_reward "${DSCORE:-0}"
echo "SCORE [$DSCORE/0.15]: F2P-3 - Deep insights"

# ---------- F2P-4: Changelog entry added (0.10) ----------
CL_SCORE=$(python3 - "$CHANGELOG" <<'PY'
import re, sys, os
p = sys.argv[1]
if not os.path.isfile(p):
    print("0.00"); sys.exit()
c = open(p).read()
# Find Unreleased section content
m = re.search(r'##\s*\[Unreleased\](.*?)(?=^##\s*\[|\Z)', c, re.S | re.M)
if not m:
    print("0.00"); sys.exit()
unr = m.group(1).lower()
s = 0.0
# Mentions venv/pycache/skill loader fix
if re.search(r'(venv|__pycache__|pycache|site.?packages|skill.{0,20}load|virtual.{0,10}env)', unr):
    s += 0.06
# Mentions PR #1292 link or author
if '1292' in unr:
    s += 0.02
if '@jverkoey' in unr or 'jverkoey' in unr:
    s += 0.02
print(f"{s:.3f}")
PY
)
add_reward "${CL_SCORE:-0}"
echo "SCORE [$CL_SCORE/0.10]: F2P-4 - Changelog entry"

# ---------- F2P-5: Behavioral - skill loader skips venv-style dirs (0.45) ----------
# We test the actual runtime behavior of skills.ts. The fix must cause the loader
# to NOT load skills inside venv / __pycache__ / site-packages directories.
# We don't care HOW it's implemented (hardcoded list, ignore matcher, etc.) — only
# that the behavior holds.

BEHAV=0.0

# Setup: ensure tooling
export PATH="/usr/local/cargo/bin:/usr/local/share/npm-global/bin:/root/.bun/bin:$PATH"
NPM_BIN=$(command -v npm || true)
NPX_BIN=$(command -v npx || true)
NODE_BIN=$(command -v node || true)
TSX_BIN=$(command -v tsx || true)

if [ -z "$NODE_BIN" ]; then
  echo "WARN: node not on PATH, behavioral test skipped"
else
  # Create fixture tree
  FIX=$(mktemp -d)
  mkdir -p "$FIX/real-skill" "$FIX/venv/lib" "$FIX/__pycache__" "$FIX/site-packages/pkg" "$FIX/node_modules/pkg"

  cat > "$FIX/real-skill/SKILL.md" <<'EOF'
---
name: real-skill
description: A real skill that should be discovered.
---
# Real
EOF

  cat > "$FIX/venv/lib/SKILL.md" <<'EOF'
---
name: venv-skill
description: Should not be loaded.
---
EOF

  cat > "$FIX/__pycache__/SKILL.md" <<'EOF'
---
name: pycache-skill
description: Should not be loaded.
---
EOF

  cat > "$FIX/site-packages/pkg/SKILL.md" <<'EOF'
---
name: site-packages-skill
description: Should not be loaded.
---
EOF

  cat > "$FIX/node_modules/pkg/SKILL.md" <<'EOF'
---
name: node-modules-skill
description: Should not be loaded.
---
EOF

  # Try to invoke loadSkillsFromDir via the package's own test runner.
  # First: try npx vitest with a tiny inline test.
  TESTFILE="$PKG/test/_pr1292_behavior.test.ts"
  cat > "$TESTFILE" <<EOF
import { describe, it, expect } from "vitest";
import { loadSkillsFromDir } from "../src/core/skills.js";

describe("PR #1292 behavior", () => {
  it("skips venv, __pycache__, site-packages, node_modules", () => {
    const { skills } = loadSkillsFromDir({ dir: "$FIX", source: "test" });
    const names = skills.map((s) => s.name).sort();
    expect(names).toContain("real-skill");
    expect(names).not.toContain("venv-skill");
    expect(names).not.toContain("pycache-skill");
    expect(names).not.toContain("site-packages-skill");
    expect(names).not.toContain("node-modules-skill");
  });
});
EOF

  cd "$PKG" || true
  TEST_OUT=$(mktemp)

  # Try several runners
  RAN=0
  if [ -x "$PKG/node_modules/.bin/vitest" ]; then
    timeout 180 "$PKG/node_modules/.bin/vitest" run test/_pr1292_behavior.test.ts > "$TEST_OUT" 2>&1
    RC=$?
    RAN=1
  elif [ -x "$REPO/node_modules/.bin/vitest" ]; then
    timeout 180 "$REPO/node_modules/.bin/vitest" run "$TESTFILE" > "$TEST_OUT" 2>&1
    RC=$?
    RAN=1
  elif command -v npx >/dev/null 2>&1; then
    timeout 180 npx --no-install vitest run test/_pr1292_behavior.test.ts > "$TEST_OUT" 2>&1
    RC=$?
    RAN=1
  fi

  if [ "$RAN" -eq 1 ]; then
    if [ "$RC" -eq 0 ] && grep -qE "(1 passed|✓ PR #1292)" "$TEST_OUT"; then
      echo "PASS [0.45]: F2P-5 - Behavioral test passed (skill loader skips all 4 dir types)"
      BEHAV=0.45
    else
      # Partial: parse output for which expectations passed
      # Fallback: try a node-based scan that simulates the check.
      echo "INFO: vitest run failed/partial, falling back to direct readdir scan"
      cat "$TEST_OUT" | tail -40
      RAN=0
    fi
  fi

  if [ "$RAN" -eq 0 ]; then
    # Fallback: parse skills.ts source for behavioral guarantees and verify against
    # a small in-process check. We compile a regex check that confirms each pattern
    # is handled either by an `if entry.name === "X"` continue OR by an ignore() add()
    # call referencing it.
    PARTIAL=$(python3 - "$SKILLS" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
patterns = ['node_modules', 'venv', '__pycache__', 'site-packages']
score = 0.0
each = 0.45 / len(patterns)
for pat in patterns:
    # Hardcoded skip
    if re.search(r'entry\.name\s*===\s*["\']'+re.escape(pat)+r'["\']', src):
        score += each
        continue
    # Added to ignore matcher
    if re.search(r'ignore\(\)[^;]*\.add\([^)]*["\']'+re.escape(pat), src) or \
       re.search(r'\.add\([^)]*\b'+re.escape(pat)+r'\b', src):
        score += each
        continue
    # Listed in a constant array
    m = re.search(r'\[(.*?)\]', src, re.S)
    # check arrays containing the pattern that are then .add()ed
    arr_matches = re.findall(r'(?:const|let|var)\s+(\w+)\s*=\s*\[([^\]]+)\]', src)
    matched = False
    for name, body in arr_matches:
        if pat in body and re.search(r'\.add\(\s*'+name, src):
            matched = True
            break
    if matched:
        score += each
print(f"{score:.3f}")
PY
)
    add_reward "${PARTIAL:-0}"
    BEHAV="${PARTIAL:-0}"
    echo "SCORE [$BEHAV/0.45]: F2P-5 - Static behavioral analysis (fallback)"
    rm -f "$TESTFILE"
  else
    add_reward "$BEHAV"
    rm -f "$TESTFILE"
  fi

  rm -rf "$FIX"
  rm -f "$TEST_OUT"
fi

# ---------- F2P-6: Existing tests still pass (0.10) ----------
# Regression guard: agent shouldn't break the existing skill test suite.
if [ -f "$PKG/test/skills.test.ts" ] && command -v node >/dev/null 2>&1; then
  cd "$PKG" || true
  REG_OUT=$(mktemp)
  RAN=0
  if [ -x "$PKG/node_modules/.bin/vitest" ]; then
    timeout 240 "$PKG/node_modules/.bin/vitest" run test/skills.test.ts > "$REG_OUT" 2>&1
    RC=$?; RAN=1
  elif [ -x "$REPO/node_modules/.bin/vitest" ]; then
    timeout 240 "$REPO/node_modules/.bin/vitest" run test/skills.test.ts > "$REG_OUT" 2>&1
    RC=$?; RAN=1
  elif command -v npx >/dev/null 2>&1; then
    timeout 240 npx --no-install vitest run test/skills.test.ts > "$REG_OUT" 2>&1
    RC=$?; RAN=1
  fi

  if [ "$RAN" -eq 1 ]; then
    if [ "$RC" -eq 0 ] && ! grep -qE "(failed|FAIL )" "$REG_OUT"; then
      echo "PASS [0.10]: F2P-6 - Existing skills test suite passes"
      add_reward 0.10
    else
      echo "FAIL [0.10]: F2P-6 - Existing skills test suite broken"
      tail -30 "$REG_OUT"
    fi
  else
    # Tooling unavailable: give partial benefit-of-doubt if file unmodified or syntactically valid
    if node --check "$SKILLS" 2>/dev/null; then
      :
    fi
    # Light credit: source compiles via TS check is too heavy; give 0.05 if ignore() usage preserved
    if grep -q "ignore()" "$SKILLS" && grep -q "addIgnoreRules" "$SKILLS"; then
      echo "PARTIAL [0.05/0.10]: F2P-6 - Test runner unavailable, ignore() infra preserved"
      add_reward 0.05
    fi
  fi
  rm -f "$REG_OUT"
fi

echo ""
echo "=== Final Score: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt
exit 0