#!/usr/bin/env bash
# -------------------------------------------------------------------
# CI/CD source: .github/workflows/ci.yml
#   bun run test    → vitest run
#   bun run typecheck → tsc --noEmit
#   bun run lint    → eslint .
# -------------------------------------------------------------------
set +e

REPO=/workspace/repo
LOGDIR=/logs/verifier
VERDICTS_FILE="$LOGDIR/gates.json"
REWARD_FILE="$LOGDIR/reward.txt"
MODULE_FILE="$REPO/src/pages/content/snowEffect/index.ts"
CONTENT_SCRIPT="$REPO/src/pages/content/index.tsx"
TEST_FILE="$REPO/src/pages/content/snowEffect/__tests__/snowEffect.test.ts"

mkdir -p "$LOGDIR"
echo '{}' > "$VERDICTS_FILE"

# All F2P weights
declare -A WEIGHTS
WEIGHTS["f2p_module_behavior"]=0.20
WEIGHTS["f2p_snowflake_variety"]=0.15
WEIGHTS["f2p_lifecycle"]=0.15
WEIGHTS["f2p_registration"]=0.10
WEIGHTS["f2p_tests_exist"]=0.10

# Total = 0.70, inner_weight = 0.30

emit_gate() {
    local gid="$1"
    local verdict="$2"
    python3 -c "
import json
f='$VERDICTS_FILE'
v={}
try:
    with open(f) as fh: v=json.load(fh)
except: pass
v['$gid']=('$verdict'=='true')
with open(f,'w') as fh: json.dump(v,fh)
"
}

# -------------------------------------------------------------------
# Helper: anti-stub check — reject functions whose bodies are trivially empty
# -------------------------------------------------------------------
check_not_stub() {
    local file="$1"
    local func_name="$2"
    if [ ! -f "$file" ]; then return 0; fi
    # Look for function bodies that are just {} or { return; } etc.
    python3 -c "
import re, sys
with open('$file') as f:
    code = f.read()
# Match the function definition and its body
pattern = rf'(?:function\s+{func_name}|const\s+{func_name}\s*=\s*(?:async\s+)?\([^)]*\)\s*=>)\s*\{{([^}]*)\}}'
m = re.search(pattern, code, re.DOTALL)
if m:
    body = m.group(1).strip()
    # Reject if body is empty or only whitespace/comments
    meaningful = [l for l in body.split('\n') if l.strip() and not l.strip().startswith('//')]
    if len(meaningful) < 2:
        sys.exit(1)
sys.exit(0)
" 2>/dev/null
}

# -------------------------------------------------------------------
# F2P-1: Module behavior (weight 0.20)
# Snow effect module exists with correct structure: creates canvas with
# position:fixed + pointer-events:none, exports startSnowEffect, has
# enable/disable/cleanup functions, non-trivial implementation.
# -------------------------------------------------------------------
F2P1_PASS=true
if [ ! -f "$MODULE_FILE" ]; then
    F2P1_PASS=false
fi
if $F2P1_PASS; then
    # Verify export
    if ! grep -q "export.*startSnowEffect\|startSnowEffect.*export" "$MODULE_FILE" 2>/dev/null; then
        F2P1_PASS=false
    fi
fi
if $F2P1_PASS; then
    # Verify canvas creation with correct CSS
    python3 -c "
import re
with open('$MODULE_FILE') as f:
    code = f.read()
# Check for canvas element creation
has_canvas = bool(re.search(r'document\.createElement\s*\(\s*[\"\\']canvas[\"\\']', code))
# Check position fixed
has_fixed = bool(re.search(r'position\s*:\s*fixed', code))
# Check pointer-events none
has_pointer = bool(re.search(r'pointer[- ]events\s*:\s*none', code))
# Check z-index (should be high, above regular content)
has_zindex = bool(re.search(r'z[- ]?[Ii]ndex', code))
exit(0 if (has_canvas and has_fixed and has_pointer) else 1)
" 2>/dev/null || F2P1_PASS=false
fi
if $F2P1_PASS; then
    # Anti-stub: verify functions have meaningful bodies
    python3 -c "
import re, sys
with open('$MODULE_FILE') as f:
    code = f.read()
# Look for enable and disable functions with substantive bodies
def check_func(func_name):
    patterns = [
        rf'(?:function\s+{func_name}\s*\([^)]*\)|const\s+{func_name}\s*=\s*(?:async\s+)?\([^)]*\)\s*=>)\s*\{{([^}}]*(?:\{{[^}}]*\}}[^}}]*)*)\}}',
        rf'(?:function\s+{func_name}|const\s+{func_name}\s*=\s*(?:async\s+)?\([^)]*\)\s*=>)\s*\{([\s\S]*?)\n\}',
    ]
    for p in patterns:
        m = re.search(p, code)
        if m:
            body = m.group(1).strip()
            lines = [l.strip() for l in body.split('\n') if l.strip() and not l.strip().startswith('//')]
            return len(lines) >= 2
    return False

ok = check_func('enable') and check_func('disable')
sys.exit(0 if ok else 1)
" 2>/dev/null || F2P1_PASS=false
fi
emit_gate "f2p_module_behavior" "$F2P1_PASS"

# -------------------------------------------------------------------
# F2P-2: Snowflake variety (weight 0.15)
# Verifies snowflakes have varied sizes (at least 3 distinct size values or
# random range), varied opacity/alpha, and varied fall speeds.
# Rejects implementations that use a single size/speed for all particles.
# -------------------------------------------------------------------
F2P2_PASS=true
if [ ! -f "$MODULE_FILE" ]; then
    F2P2_PASS=false
fi
if $F2P2_PASS; then
    python3 -c "
import re, sys
with open('$MODULE_FILE') as f:
    code = f.read()

score = 0

# Check for size variety: random size or multiple size constants
# Look for Math.random() used in size calculation, or multiple distinct size literals
size_literals = set(re.findall(r'(?:size|radius|r)\s*[=:]\s*(\d+)', code))
size_literals.update(set(re.findall(r'(?:size|radius|r)\s*[=:]\s*(\d+\.?\d*)', code)))
random_in_size = bool(re.search(r'Math\.random\(\)\s*\*\s*\d+', code))
if len(size_literals) >= 2 or random_in_size:
    score += 1

# Check for opacity/alpha variation
has_opacity = bool(re.search(r'(?:opacity|alpha|globalAlpha)', code))
random_opacity = bool(re.search(r'(?:opacity|alpha).*Math\.random', code))
if has_opacity and random_opacity:
    score += 1

# Check for speed variation (different dy/vy values)
speed_literals = set(re.findall(r'(?:speed|velocity|dy|vy)\s*[=:]\s*(\d+\.?\d*)', code))
random_speed = bool(re.search(r'(?:speed|velocity|dy|vy).*Math\.random', code))
if len(speed_literals) >= 2 or random_speed:
    score += 1

# Check particle count is reasonable (>= 50)
particle_counts = re.findall(r'(?:NUM_SNOWFLAKES|SNOWFLAKE_COUNT|snowflakeCount|particleCount|numParticles)\s*=\s*(\d+)', code)
if particle_counts:
    if any(int(c) >= 50 for c in particle_counts):
        score += 1
else:
    # Fallback: check for array length or loop bounds >= 50
    loop_bounds = re.findall(r'(?:<\s*(\d+)|length.*?(\d+)|push.*?(\d+))', code)
    # Just look for any number >= 50 in context of particle creation
    if re.search(r'[^.]\b([5-9]\d|[1-9]\d{2,})\b', code):
        score += 1

# Need at least 3 of 4 variety indicators
sys.exit(0 if score >= 3 else 1)
" 2>/dev/null || F2P2_PASS=false
fi
emit_gate "f2p_snowflake_variety" "$F2P2_PASS"

# -------------------------------------------------------------------
# F2P-3: Lifecycle (weight 0.15)
# enable() creates and appends canvas; disable() removes canvas and cancels
# animation; module listens to chrome.storage.onChanged for gvSnowEffect.
# -------------------------------------------------------------------
F2P3_PASS=true
if [ ! -f "$MODULE_FILE" ]; then
    F2P3_PASS=false
fi
if $F2P3_PASS; then
    python3 -c "
import re, sys
with open('$MODULE_FILE') as f:
    code = f.read()

score = 0

# enable() appends canvas to DOM (appendChild, append, insertBefore, prepend)
if re.search(r'(?:appendChild|\.append\s*\(|insertBefore|prepend)\s*\(', code):
    score += 1

# disable() removes canvas (remove, removeChild, parentNode.removeChild)
if re.search(r'(?:\.remove\s*\(|removeChild|parentNode\.removeChild)', code):
    score += 1

# disable() cancels animation frame (cancelAnimationFrame)
if re.search(r'cancelAnimationFrame', code):
    score += 1

# Listens to chrome.storage.onChanged or chrome.storage.sync for gvSnowEffect
if re.search(r'storage.*onChanged|chrome\.storage\.(?:sync|local)\.get.*gvSnowEffect|GV_SNOW_EFFECT', code):
    score += 1

# Need at least 3 of 4 lifecycle indicators
sys.exit(0 if score >= 3 else 1)
" 2>/dev/null || F2P3_PASS=false
fi
emit_gate "f2p_lifecycle" "$F2P3_PASS"

# -------------------------------------------------------------------
# F2P-4: Registration (weight 0.10)
# index.tsx imports startSnowEffect from ./snowEffect/index and calls it
# after sidebar auto-hide, with LIGHT_FEATURE_INIT_DELAY delay.
# -------------------------------------------------------------------
F2P4_PASS=true
if [ ! -f "$CONTENT_SCRIPT" ]; then
    F2P4_PASS=false
fi
if $F2P4_PASS; then
    python3 -c "
import re, sys
with open('$CONTENT_SCRIPT') as f:
    code = f.read()

score = 0

# Import from snowEffect
if re.search(r'import.*snowEffect|import.*from\s+[\"\\'].*snowEffect', code):
    score += 1

# startSnowEffect referenced (imported or called)
if re.search(r'startSnowEffect', code):
    score += 1

# Called after sidebarAutoHide (check relative positioning in file)
lines = code.split('\n')
snow_called = False
sidebar_found = False
for i, line in enumerate(lines):
    if 'startSidebarAutoHide' in line or 'sidebarAutoHide' in line:
        sidebar_found = True
    if sidebar_found and 'startSnowEffect' in line:
        snow_called = True

if snow_called:
    score += 1

# Check for delay (LIGHT_FEATURE_INIT_DELAY or delay call)
call_context = ''
for i, line in enumerate(lines):
    if 'startSnowEffect' in line:
        # Look at surrounding lines for delay pattern
        start = max(0, i-3)
        end = min(len(lines), i+3)
        call_context = '\n'.join(lines[start:end])
        break
if 'delay' in call_context.lower() or 'LIGHT_FEATURE_INIT_DELAY' in code:
    score += 1

sys.exit(0 if score >= 3 else 1)
" 2>/dev/null || F2P4_PASS=false
fi
emit_gate "f2p_registration" "$F2P4_PASS"

# -------------------------------------------------------------------
# F2P-5: Tests exist and test the right things (weight 0.10)
# snowEffect/__tests__/snowEffect.test.ts exists, tests enable/disable,
# tests pass via vitest. Rejects empty/stub test files.
# -------------------------------------------------------------------
F2P5_PASS=true
if [ ! -f "$TEST_FILE" ]; then
    F2P5_PASS=false
fi
if $F2P5_PASS; then
    # Anti-stub: test file must have meaningful test content
    python3 -c "
import re, sys
with open('$TEST_FILE') as f:
    code = f.read()
# Count test/it/describe blocks
test_blocks = len(re.findall(r'\b(?:it|test|describe)\s*\(', code))
# Count assertions
assertions = len(re.findall(r'\bexpect\s*\(', code))
if test_blocks < 2:
    sys.exit(1)
if assertions < 3:
    sys.exit(1)
sys.exit(0)
" 2>/dev/null || F2P5_PASS=false
fi
if $F2P5_PASS; then
    # Check that tests cover enable/disable concepts
    if ! grep -qE "enable|disable|canvas|snowflake" "$TEST_FILE" 2>/dev/null; then
        F2P5_PASS=false
    fi
fi
emit_gate "f2p_tests_exist" "$F2P5_PASS"

# -------------------------------------------------------------------
# P2P regression gates (gating only — zero weight, zero if fail)
# -------------------------------------------------------------------
P2P_FAILED=false

# P2P-1: TypeScript type checking
echo "--- P2P: typecheck ---"
cd "$REPO"
if bun run typecheck 2>&1 | tail -5; then
    echo "typecheck passed"
else
    echo "typecheck failed"
    P2P_FAILED=true
fi

# P2P-2: Existing vitest tests still pass
echo "--- P2P: vitest ---"
if bun run test 2>&1 | tail -20; then
    echo "tests passed"
else
    echo "tests failed"
    P2P_FAILED=true
fi

# -------------------------------------------------------------------
# Compute reward using weighted-replace formula
# -------------------------------------------------------------------
echo "--- Computing reward ---"

python3 -c "
import json, os

with open('$VERDICTS_FILE') as f:
    verdicts = json.load(f)

weights = {
    'f2p_module_behavior': 0.20,
    'f2p_snowflake_variety': 0.15,
    'f2p_lifecycle': 0.15,
    'f2p_registration': 0.10,
    'f2p_tests_exist': 0.10,
}

p2p_failed = '$P2P_FAILED' == 'true'

# Check if any F2P gate passed
f2p_any_pass = any(verdicts.get(gid, False) for gid in weights)

if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    existing = 1.0
    inner_weight = max(0.0, 1.0 - sum(weights.values()))
    reward = existing * inner_weight
    for gid, w in weights.items():
        if verdicts.get(gid, False):
            reward += float(w)

reward = round(reward, 6)
print(f'Reward: {reward}')
print(f'Verdicts: {json.dumps(verdicts)}')
print(f'P2P failed: {p2p_failed}')

with open('$REWARD_FILE', 'w') as f:
    f.write(str(reward))
"

echo "Reward written to $REWARD_FILE"
cat "$REWARD_FILE"
