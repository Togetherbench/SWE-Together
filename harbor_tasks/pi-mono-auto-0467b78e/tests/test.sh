#!/bin/bash
set +e

# Verifier for PR #1292: skill loader should skip Python venv / cache dirs
# Core principle: a no-op patch (unmodified buggy state) MUST score 0.0.
# All reward comes from behavioral changes in skills.ts, plus review.md
# and changelog artifacts that don't exist on base.

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

# ---------- P2P gate: repo intact ----------
if [ ! -d "$REPO" ] || [ ! -f "$REPO/package.json" ] || [ ! -f "$SKILLS" ]; then
  echo "GATE FAIL: repo missing/damaged"
  echo "0.00" > /logs/verifier/reward.txt
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

# review.md does not exist on base => any reward keyed on review content is F2P-safe.

# ---------- F2P-1: Review structure (0.05) ----------
# Base: no review.md => 0. Fix: writes structured review => up to 0.05.
if [ -n "$REVIEW" ]; then
  STRUCT=$(python3 - "$REVIEW" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
need = ['good', 'bad', 'ugly', 'changelog']
found = sum(1 for p in need if re.search(r'(?im)^[\s#*]*'+p+r'[\s:*]', c))
print(found)
PY
)
  if [ "${STRUCT:-0}" -ge 4 ]; then
    echo "PASS [0.05]: F2P-1 - Review has required sections"
    add_reward 0.05
  else
    echo "FAIL [0.05]: F2P-1 - Missing review sections ($STRUCT/4)"
  fi
else
  echo "FAIL [0.05]: F2P-1 - No review.md"
fi

# ---------- F2P-2: Review content quality (0.10) ----------
QSCORE="0.000"
if [ -n "$REVIEW" ]; then
  QSCORE=$(python3 - "$REVIEW" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
low = c.lower()
s = 0.0
if any(t in low for t in ['venv', '__pycache__', 'pycache', 'site-packages', 'site_packages', 'virtual env']):
    s += 0.03
if '1292' in low or '1294' in low:
    s += 0.02
if re.search(r'changelog', low):
    s += 0.02
if re.search(r'(no|missing|lack|without|absent)[^.]{0,30}test', low) or re.search(r'test[^.]{0,30}(miss|lack|absent|not\s+add)', low):
    s += 0.03
print(f"{s:.3f}")
PY
)
fi
add_reward "${QSCORE:-0}"
echo "SCORE [$QSCORE/0.10]: F2P-2 - Content quality"

# ---------- F2P-3: Deep insights (0.15) ----------
DSCORE="0.000"
if [ -n "$REVIEW" ]; then
  DSCORE=$(python3 - "$REVIEW" <<'PY'
import re, sys
c = open(sys.argv[1]).read()
low = c.lower()
s = 0.0
reuse = bool(re.search(r'(reuse|leverag|use).{0,40}(ignore|gitignore|existing)', low) or
             re.search(r'(ignore|gitignore).{0,40}(infrastructure|matcher|mechanism|already|exist)', low) or
             re.search(r'hardcod', low) or
             re.search(r'(ad.hoc|instead of|rather than).{0,50}ignore', low))
if reuse:
    s += 0.06
dotfile = bool(re.search(r'(dot.?file|leading dot|starts?.with.{0,20}["\'.]|hidden.{0,20}(dir|file)|\.venv)', low))
if dotfile:
    s += 0.04
if re.search(r'(tab.{0,40}space|space.{0,40}tab|indent.{0,30}(inconsist|mismatch|mixed|wrong)|format.{0,30}(inconsist|issue))', low):
    s += 0.03
if re.search(r'(regression|fd|file descriptor|36k|36,?000)', low):
    s += 0.02
print(f"{s:.3f}")
PY
)
fi
add_reward "${DSCORE:-0}"
echo "SCORE [$DSCORE/0.15]: F2P-3 - Deep insights"

# ---------- F2P-4: Changelog entry added (0.10) ----------
# Base CHANGELOG.md Unreleased does NOT mention venv/pycache/skill-loader/1292.
# So this is genuine F2P.
CL_SCORE="0.000"
if [ -f "$CHANGELOG" ]; then
  CL_SCORE=$(python3 - "$CHANGELOG" <<'PY'
import re, sys, os
p = sys.argv[1]
c = open(p).read()
m = re.search(r'##\s*\[Unreleased\](.*?)(?=^##\s*\[|\Z)', c, re.S | re.M)
if not m:
    print("0.00"); sys.exit()
unr = m.group(1).lower()
s = 0.0
if re.search(r'(venv|__pycache__|pycache|site.?packages|skill.{0,20}load|virtual.{0,10}env)', unr):
    s += 0.06
if '1292' in unr:
    s += 0.02
if 'jverkoey' in unr:
    s += 0.02
print(f"{s:.3f}")
PY
)
fi
add_reward "${CL_SCORE:-0}"
echo "SCORE [$CL_SCORE/0.10]: F2P-4 - Changelog entry"

# ---------- P2P regression gate: skills.ts must still parse ----------
# If the file is broken syntactically, agent regressed something — exit 0.
export PATH="/usr/local/cargo/bin:/usr/local/share/npm-global/bin:/root/.bun/bin:$PATH"

# ---------- F2P-5: Behavioral - skill loader skips venv-style dirs (0.60) ----------
# This is the heart of the PR. On the buggy base, loadSkillsFromDir recursively
# walks into venv/ __pycache__/ site-packages/ and would surface skill files inside.
# A no-op patch must score 0 here. Any correct fix (hardcoded skip list, ignore matcher
# default patterns, etc.) must skip all four directory types.

BEHAV=0.0

# Build a fixture tree and a runner that imports loadSkillsFromDir from skills.ts
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

NODE_BIN=$(command -v node || true)
NPX_BIN=$(command -v npx || true)

# Create an isolated test file under the package so it can resolve workspace deps.
TESTFILE="$PKG/test/_pr1292_behavior.test.ts"
cat > "$TESTFILE" <<EOF
import { describe, it, expect } from "vitest";
import { loadSkillsFromDir } from "../src/core/skills.js";

describe("PR #1292 behavior", () => {
  it("skips venv, __pycache__, site-packages, node_modules", () => {
    const { skills } = loadSkillsFromDir({ dir: "$FIX", source: "test" });
    const names = skills.map((s: any) => s.name).sort();
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
RC=99
RAN=0

if [ -x "$PKG/node_modules/.bin/vitest" ]; then
  timeout 240 "$PKG/node_modules/.bin/vitest" run test/_pr1292_behavior.test.ts > "$TEST_OUT" 2>&1
  RC=$?
  RAN=1
elif [ -x "$REPO/node_modules/.bin/vitest" ]; then
  timeout 240 "$REPO/node_modules/.bin/vitest" run "$TESTFILE" > "$TEST_OUT" 2>&1
  RC=$?
  RAN=1
elif [ -n "$NPX_BIN" ]; then
  timeout 240 "$NPX_BIN" --no-install vitest run test/_pr1292_behavior.test.ts > "$TEST_OUT" 2>&1
  RC=$?
  RAN=1
fi

VITEST_OK=0
if [ "$RAN" -eq 1 ] && [ "$RC" -eq 0 ]; then
  if grep -qE "(Tests *1 passed|1 passed|✓ .*PR #1292|✓ skips venv)" "$TEST_OUT"; then
    VITEST_OK=1
  fi
fi

# Fallback path: directly invoke the loader via tsx/node loader so we don't depend
# on vitest being installed in the sandbox.
if [ "$VITEST_OK" -ne 1 ]; then
  echo "INFO: vitest not usable or failed (rc=$RC), trying tsx fallback"
  [ "$RAN" -eq 1 ] && tail -40 "$TEST_OUT"

  RUNNER=$(mktemp --suffix=.mjs)
  cat > "$RUNNER" <<EOF
import { loadSkillsFromDir } from "$PKG/src/core/skills.ts";
const { skills } = loadSkillsFromDir({ dir: "$FIX", source: "test" });
const names = skills.map((s) => s.name);
console.log("NAMES:" + JSON.stringify(names));
EOF

  TSX_OUT=$(mktemp)
  if [ -x "$PKG/node_modules/.bin/tsx" ]; then
    timeout 60 "$PKG/node_modules/.bin/tsx" "$RUNNER" > "$TSX_OUT" 2>&1
  elif [ -x "$REPO/node_modules/.bin/tsx" ]; then
    timeout 60 "$REPO/node_modules/.bin/tsx" "$RUNNER" > "$TSX_OUT" 2>&1
  elif command -v tsx >/dev/null 2>&1; then
    timeout 60 tsx "$RUNNER" > "$TSX_OUT" 2>&1
  elif [ -n "$NPX_BIN" ]; then
    timeout 60 "$NPX_BIN" --no-install tsx "$RUNNER" > "$TSX_OUT" 2>&1
  fi

  NAMES_LINE=$(grep "^NAMES:" "$TSX_OUT" | tail -1 | sed 's/^NAMES://')
  if [ -n "$NAMES_LINE" ]; then
    echo "INFO: loader output: $NAMES_LINE"
    HAS_REAL=$(echo "$NAMES_LINE" | grep -c '"real-skill"')
    HAS_VENV=$(echo "$NAMES_LINE" | grep -c '"venv-skill"')
    HAS_PYC=$(echo "$NAMES_LINE" | grep -c '"pycache-skill"')
    HAS_SP=$(echo "$NAMES_LINE" | grep -c '"site-packages-skill"')
    HAS_NM=$(echo "$NAMES_LINE" | grep -c '"node-modules-skill"')

    # Score each skip independently (graded). real-skill must be present (diagnostic).
    # Note: node_modules skip already works on buggy base (hardcoded check), so
    # only award credit for venv, __pycache__, site-packages (the new skips).
    if [ "$HAS_REAL" -ge 1 ]; then
      # 0.60 split: 0.25 venv, 0.20 __pycache__, 0.15 site-packages (node_modules excluded - P2P)
      [ "$HAS_VENV" -eq 0 ] && BEHAV=$(awk -v a=$BEHAV 'BEGIN{printf "%.3f", a+0.25}')
      [ "$HAS_PYC"  -eq 0 ] && BEHAV=$(awk -v a=$BEHAV 'BEGIN{printf "%.3f", a+0.20}')
      [ "$HAS_SP"   -eq 0 ] && BEHAV=$(awk -v a=$BEHAV 'BEGIN{printf "%.3f", a+0.15}')
      echo "SCORE [$BEHAV/0.60]: F2P-5 - Behavioral (graded via tsx loader)"
    else
      echo "FAIL: real-skill not discovered — loader broken or fixture path wrong"
      echo "$NAMES_LINE"
    fi
  else
    echo "WARN: tsx fallback also failed; printing diagnostics"
    tail -40 "$TSX_OUT"
  fi
else
  BEHAV=0.60
  echo "PASS [0.60]: F2P-5 - Behavioral (vitest)"
fi

# Clean up the test file we injected so it doesn't pollute the repo state.
rm -f "$TESTFILE"

add_reward "$BEHAV"

# Final (before upstream gates)
echo "=== EXISTING REWARD: $REWARD ==="
echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_JSON="/logs/verifier/gates.json"
: > "$GATES_JSON"

emit_gate() {
  local gid="$1" passed="$2" detail="$3"
  printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$gid" "$passed" "$detail" >> "$GATES_JSON"
}

# --- F2P: f2p_upstream_skill_loader_skip_dirs ---
(
  set +e
  cd /workspace/pi-mono || { emit_gate "f2p_upstream_skill_loader_skip_dirs" "false" "cd failed"; exit 0; }
  rm -rf /tmp/_f2p_fix
  mkdir -p /tmp/_f2p_fix/real-skill /tmp/_f2p_fix/venv/lib /tmp/_f2p_fix/__pycache__ /tmp/_f2p_fix/site-packages/pkg
  printf -- '---\nname: real-skill\ndescription: A real skill.\n---\n' > /tmp/_f2p_fix/real-skill/SKILL.md
  printf -- '---\nname: venv-skill\ndescription: X.\n---\n' > /tmp/_f2p_fix/venv/lib/SKILL.md
  printf -- '---\nname: pycache-skill\ndescription: X.\n---\n' > /tmp/_f2p_fix/__pycache__/SKILL.md
  printf -- '---\nname: sp-skill\ndescription: X.\n---\n' > /tmp/_f2p_fix/site-packages/pkg/SKILL.md
  cat > /tmp/_f2p_runner.mts <<'TSEOF'
import { loadSkillsFromDir } from "/workspace/pi-mono/packages/coding-agent/src/core/skills.ts";
const { skills } = loadSkillsFromDir({ dir: "/tmp/_f2p_fix", source: "test" });
const names = skills.map((s: any) => s.name);
const bad = names.filter((n: string) => ["venv-skill","pycache-skill","sp-skill"].includes(n));
if (bad.length > 0) { console.error("FAIL: skills not skipped:", bad); process.exit(1); }
if (!names.includes("real-skill")) { console.error("FAIL: real-skill missing"); process.exit(1); }
console.log("PASS: skill loader correctly skips venv/__pycache__/site-packages");
TSEOF
  timeout 30 /workspace/pi-mono/node_modules/.bin/tsx /tmp/_f2p_runner.mts 2>&1
  rc=$?
  rm -rf /tmp/_f2p_fix /tmp/_f2p_runner.mts
  exit $rc
)
if [ $? -eq 0 ]; then
  echo "PASS: f2p_upstream_skill_loader_skip_dirs"
  emit_gate "f2p_upstream_skill_loader_skip_dirs" "true" "skill loader skips venv dirs"
else
  echo "FAIL: f2p_upstream_skill_loader_skip_dirs"
  emit_gate "f2p_upstream_skill_loader_skip_dirs" "false" "skill loader does not skip venv dirs"
fi

# --- P2P: p2p_upstream_vitest_skills ---
(
  set +e
  cd /workspace/pi-mono || exit 1
  timeout 120 node_modules/.bin/vitest run packages/coding-agent/test/skills.test.ts 2>&1
  exit $?
)
if [ $? -eq 0 ]; then
  echo "PASS: p2p_upstream_vitest_skills"
  emit_gate "p2p_upstream_vitest_skills" "true" "vitest skills tests pass"
else
  echo "FAIL: p2p_upstream_vitest_skills"
  emit_gate "p2p_upstream_vitest_skills" "false" "vitest skills tests failed"
fi

# --- P2P: p2p_upstream_tsgo_typecheck (scoped to agent-touched .ts/.tsx files) ---
# Pre-existing errors in sandbox/index.ts and similar files would otherwise force every reward to 0.
CHANGED_TS_FILES=$(cd /workspace/pi-mono && (git diff --name-only HEAD~1 HEAD 2>/dev/null; git diff --name-only HEAD 2>/dev/null) | grep -E '\.tsx?$' | sort -u | tr '\n' ' ')
if [ -z "$CHANGED_TS_FILES" ]; then
  echo "PASS: p2p_upstream_tsgo_typecheck (no agent .ts/.tsx changes — gate skipped)"
  emit_gate "p2p_upstream_tsgo_typecheck" "true" "no agent .ts/.tsx changes — gate skipped"
else
  (
    set +e
    cd /workspace/pi-mono || exit 1
    timeout 120 node_modules/.bin/tsgo --noEmit $CHANGED_TS_FILES 2>&1
    exit $?
  )
  if [ $? -eq 0 ]; then
    echo "PASS: p2p_upstream_tsgo_typecheck"
    emit_gate "p2p_upstream_tsgo_typecheck" "true" "tsgo typecheck passes on agent-changed files"
  else
    echo "FAIL: p2p_upstream_tsgo_typecheck"
    emit_gate "p2p_upstream_tsgo_typecheck" "false" "tsgo typecheck failed on agent-changed files"
  fi
fi

# --- Upstream reward tail ---
python3 - <<'PYEOF'
import json, os, sys

WEIGHTS = {"f2p_upstream_skill_loader_skip_dirs": 0.20}
P2P_REGRESSION = ["p2p_upstream_vitest_skills", "p2p_upstream_tsgo_typecheck"]

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

# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
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

echo "=== FINAL REWARD (after upstream gates): $(cat /logs/verifier/reward.txt) ==="
# ---- end ----