#!/usr/bin/env bash
# CI/CD source: .github/workflows/python-checks.yml
# Upstream test command: pytest ./tests/ --cov=custom_components/lock_code_manager/ --cov-report=xml --junitxml=junit.xml
set +e

REWARD_FILE="/logs/verifier/reward.txt"
REPO_DIR="/workspace/lock_code_manager"
BASE_PY="$REPO_DIR/custom_components/lock_code_manager/providers/_base.py"
INIT_PY="$REPO_DIR/custom_components/lock_code_manager/__init__.py"

# WEIGHTS dictionary (parsed by lint_tests.py for R004/R007 checks). Sum must be in (0, 1.0].
# Sum check: 0.15 + 0.15 + 0.15 + 0.15 + 0.15 + 0.05 + 0.05 + 0.05 = 0.90
WEIGHTS='{"gold_setup_complete_field": 0.15, "gold_setup_complete_both_paths": 0.15, "gold_lock_reuse_await": 0.15, "gold_safe_unsub_flag": 0.15, "silver_all_tests_pass": 0.15, "silver_new_tests_exist": 0.05, "bronze_anti_stub_async_setup": 0.05, "bronze_on_started_nonlocal": 0.05}'

echo "0.0" > "$REWARD_FILE"

# ===========================================================================
# F2P VERDICTS (feature-to-pass)
# ===========================================================================

# --- GOLD: _setup_complete Event exists in BaseLock with asyncio.Event type ---
gid_g1="gold_setup_complete_field"
v_g1=0

python3 -c "
import ast
tree = ast.parse(open('$BASE_PY').read())
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == 'BaseLock':
        for item in node.body:
            if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name):
                if item.target.id == '_setup_complete':
                    ann = item.annotation
                    if isinstance(ann, ast.Attribute):
                        if isinstance(ann.value, ast.Name) and ann.value.id == 'asyncio' and ann.attr == 'Event':
                            # Also verify default_factory=asyncio.Event, init=False
                            if item.value and isinstance(item.value, ast.Call):
                                call = item.value
                                if isinstance(call.func, ast.Name) and call.func.id == 'field':
                                    has_event_factory = False
                                    has_init_false = False
                                    for kw in call.keywords:
                                        if kw.arg == 'default_factory':
                                            df = kw.value
                                            if isinstance(df, ast.Attribute) and isinstance(df.value, ast.Name):
                                                if df.value.id == 'asyncio' and df.attr == 'Event':
                                                    has_event_factory = True
                                        if kw.arg == 'init':
                                            if isinstance(kw.value, ast.Constant) and kw.value.value is False:
                                                has_init_false = True
                                    if has_event_factory and has_init_false:
                                        print('FOUND')
                                        exit(0)
print('NOT_FOUND')
exit(1)
" 2>/dev/null && v_g1=1

# --- GOLD: async_setup() sets _setup_complete in BOTH the early-return path AND the normal completion ---
gid_g2="gold_setup_complete_both_paths"
v_g2=0

python3 -c "
import ast
tree = ast.parse(open('$BASE_PY').read())
for node in ast.walk(tree):
    if isinstance(node, ast.AsyncFunctionDef) and node.name == 'async_setup':
        # Count all self._setup_complete.set() calls in the function
        set_count = 0
        early_return_has_set = False
        for sub in ast.walk(node):
            if isinstance(sub, ast.Expr) and isinstance(sub.value, ast.Call):
                call = sub.value
                if isinstance(call.func, ast.Attribute) and call.func.attr == 'set':
                    full = ast.unparse(call.func.value)
                    if full == 'self._setup_complete':
                        set_count += 1
                        # Check if this is inside the early-return if block
                        for parent in ast.walk(node):
                            if isinstance(parent, ast.If):
                                test_str = ast.unparse(parent.test)
                                if 'coordinator' in test_str and 'not None' in test_str:
                                    # Walk the if body for this .set() call
                                    for inner in ast.walk(parent):
                                        if inner is sub:
                                            early_return_has_set = True
                                            break
        # We need at least 2: one in normal flow, one in early return
        if set_count >= 2:
            print(f'SET_COUNT={set_count} EARLY_RETURN={early_return_has_set}')
            exit(0)
        else:
            print(f'SET_COUNT={set_count} (need >=2)')
            exit(1)
print('async_setup not found')
exit(1)
" 2>/dev/null && v_g2=1

# --- GOLD: async_update_listener awaits lock._setup_complete.wait() on reuse path ---
gid_g3="gold_lock_reuse_await"
v_g3=0

python3 -c "
import ast
tree = ast.parse(open('$INIT_PY').read())
for node in ast.walk(tree):
    if isinstance(node, ast.AsyncFunctionDef) and node.name == 'async_update_listener':
        source = ast.unparse(node)
        # Check for the pattern: lock_entity_id in hass_data[CONF_LOCKS]
        # followed by await ..._setup_complete.wait()
        if 'CONF_LOCKS' in source and 'hass_data' in source:
            # Find await on _setup_complete.wait() within a CONF_LOCKS check
            for sub in ast.walk(node):
                if isinstance(sub, ast.If):
                    test_str = ast.unparse(sub.test)
                    if 'CONF_LOCKS' in test_str:
                        for inner in ast.walk(sub):
                            if isinstance(inner, ast.Await):
                                await_expr = ast.unparse(inner.value)
                                if '_setup_complete' in await_expr and 'wait' in await_expr:
                                    print('FOUND await _setup_complete.wait() in lock reuse path')
                                    exit(0)
print('NOT_FOUND')
exit(1)
" 2>/dev/null && v_g3=1

# --- GOLD: _safe_unsub checks flag before unsub (not try/except ValueError) ---
gid_g4="gold_safe_unsub_flag"
v_g4=0

python3 -c "
import ast
tree = ast.parse(open('$INIT_PY').read())
for node in ast.walk(tree):
    if isinstance(node, ast.AsyncFunctionDef) and node.name == 'async_setup_entry':
        for sub in ast.walk(node):
            if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and sub.name == '_safe_unsub':
                body_code = ast.unparse(sub)
                # Pattern: must use if check before calling unsub()
                has_conditional_unsub = False
                has_try_except = False
                for deeper in ast.walk(sub):
                    if isinstance(deeper, ast.Try):
                        # Check handlers for ValueError
                        for h in deeper.handlers:
                            if isinstance(h.type, ast.Name) and h.type.id == 'ValueError':
                                has_try_except = True
                    if isinstance(deeper, ast.If):
                        if_test = ast.unparse(deeper.test)
                        # Look for 'not started' or 'not <flag>'
                        if 'unsub()' in ast.unparse(deeper):
                            has_conditional_unsub = True
                # Verify: calls unsub conditionally, no try/except ValueError
                calls_unsub = 'unsub()' in body_code
                if calls_unsub and not has_try_except and 'if' in body_code:
                    print('FOUND flag-guarded _safe_unsub')
                    exit(0)
print('NOT_FOUND')
exit(1)
" 2>/dev/null && v_g4=1

# --- SILVER: pytest passes all tests ---
gid_s1="silver_all_tests_pass"
v_s1=0

cd "$REPO_DIR"
pytest tests/ -x -q --tb=short 2>&1 | tee /logs/verifier/pytest.log
pytest_rc=$?
if [ "$pytest_rc" = "0" ]; then
    v_s1=1
fi

# --- SILVER: new overlapping locks test exists and passes ---
gid_s2="silver_new_tests_exist"
v_s2=0

# Check for any new test file beyond the existing ones that tests overlapping/shared locks
# Look for test functions related to overlapping locks or the race condition
python3 -c "
import ast, os, sys
test_dir = '$REPO_DIR/tests'
found = False
for root, dirs, files in os.walk(test_dir):
    for f in files:
        if f.endswith('.py') and f != '__init__.py':
            fpath = os.path.join(root, f)
            try:
                tree = ast.parse(open(fpath).read())
                for node in ast.walk(tree):
                    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        name = node.name
                        # Look for test names that suggest overlapping/shared lock testing
                        if 'overlap' in name.lower() or 'shared_lock' in name.lower() or \
                           'both_entries' in name.lower() or 'setup_complete' in name.lower() or \
                           'two_entries_same' in name.lower() or 'concurrent' in name.lower():
                            found = True
                            print(f'FOUND test: {name} in {fpath}')
            except SyntaxError:
                pass
if found:
    exit(0)
exit(1)
" 2>/dev/null && v_s2=1

# --- BRONZE: anti-stub check for async_setup ---
gid_b1="bronze_anti_stub_async_setup"
v_b1=0

python3 -c "
import ast
tree = ast.parse(open('$BASE_PY').read())
for node in ast.walk(tree):
    if isinstance(node, ast.AsyncFunctionDef) and node.name == 'async_setup':
        stmt_count = sum(1 for s in node.body if not isinstance(s, (ast.Pass, ast.Expr)))
        if stmt_count > 3:
            exit(0)
exit(1)
" 2>/dev/null && v_b1=1

# --- BRONZE: _on_started callback exists and sets a flag ---
gid_b2="bronze_on_started_nonlocal"
v_b2=0

python3 -c "
import ast
tree = ast.parse(open('$INIT_PY').read())
for node in ast.walk(tree):
    if isinstance(node, ast.AsyncFunctionDef) and node.name == 'async_setup_entry':
        # Find nested _on_started function inside async_setup_entry
        for sub in ast.walk(node):
            if isinstance(sub, (ast.FunctionDef, ast.AsyncFunctionDef)) and sub.name == '_on_started':
                body_code = ast.unparse(sub)
                # Must use nonlocal
                if 'nonlocal' in body_code:
                    exit(0)
print('NOT_FOUND')
exit(1)
" 2>/dev/null && v_b2=1

# ===========================================================================
# P2P_REGRESSION GATES (gating only, zero on fail)
# ===========================================================================
p2p_failed=0

# P2P: No syntax errors in modified files
python3 -c "import py_compile; py_compile.compile('$BASE_PY', doraise=True)" 2>/dev/null || {
    echo "P2P FAIL: syntax error in _base.py"
    p2p_failed=1
}
python3 -c "import py_compile; py_compile.compile('$INIT_PY', doraise=True)" 2>/dev/null || {
    echo "P2P FAIL: syntax error in __init__.py"
    p2p_failed=1
}

# P2P: Test suite collected tests (rc=5 = no tests collected)
if [ "$pytest_rc" = "5" ]; then
    echo "P2P FAIL: no tests collected"
    p2p_failed=1
fi

# P2P: files actually exist
[ -f "$BASE_PY" ] || { echo "P2P FAIL: _base.py missing"; p2p_failed=1; }
[ -f "$INIT_PY" ] || { echo "P2P FAIL: __init__.py missing"; p2p_failed=1; }

# ===========================================================================
# COMPUTE REWARD (weighted-replace formula)
# ===========================================================================

# Weights sum must be <= 1.0
# gold_setup_complete_field:       0.15
# gold_setup_complete_set_in_both: 0.15
# gold_lock_reuse_await_setup:     0.15
# gold_safe_unsub_flag_pattern:    0.15
# silver_all_tests_pass:           0.15
# silver_new_test_exists:          0.05
# bronze_async_setup_not_stub:     0.05
# bronze_on_started_has_started:   0.05
# TOTAL:                           0.90

G1_W=0.15; G2_W=0.15; G3_W=0.15; G4_W=0.15
S1_W=0.15; S2_W=0.05; B1_W=0.05; B2_W=0.05

total_weight=$(python3 -c "print($G1_W + $G2_W + $G3_W + $G4_W + $S1_W + $S2_W + $B1_W + $B2_W)")
inner_weight=$(python3 -c "print(max(0.0, 1.0 - $total_weight))")

# Check if any F2P gate passed
f2p_any_pass=0
for v in $v_g1 $v_g2 $v_g3 $v_g4 $v_s1 $v_s2 $v_b1 $v_b2; do
    [ "$v" = "1" ] && f2p_any_pass=1 && break
done

if [ "$p2p_failed" = "1" ] || [ "$f2p_any_pass" = "0" ]; then
    python3 -c "
p2p = $p2p_failed
f2p = $f2p_any_pass
print(f'P2P failed={p2p}, F2P any pass={f2p}')
print('REWARD=0.0')
" >&2
    echo "0.0" > "$REWARD_FILE"
    echo "P2P_REGRESSION blocked or no F2P gates passed"
else
    reward=$(python3 -c "
existing = 0.0
inner_w = $inner_weight
w_map = {
    'g1': ($G1_W, $v_g1),
    'g2': ($G2_W, $v_g2),
    'g3': ($G3_W, $v_g3),
    'g4': ($G4_W, $v_g4),
    's1': ($S1_W, $v_s1),
    's2': ($S2_W, $v_s2),
    'b1': ($B1_W, $v_b1),
    'b2': ($B2_W, $v_b2),
}
reward = existing * inner_w
for gate_id, (w, passed) in w_map.items():
    if passed:
        reward += w
print(f'{reward:.6f}')
")
    echo "$reward" > "$REWARD_FILE"
fi

echo ""
echo "=== VERIFICATION RESULTS ==="
echo "gold_setup_complete_field=$v_g1"
echo "gold_setup_complete_both_paths=$v_g2"
echo "gold_lock_reuse_await=$v_g3"
echo "gold_safe_unsub_flag=$v_g4"
echo "silver_all_tests_pass=$v_s1"
echo "silver_new_tests_exist=$v_s2"
echo "bronze_anti_stub_async_setup=$v_b1"
echo "bronze_on_started_nonlocal=$v_b2"
echo "p2p_failed=$p2p_failed"
echo "f2p_any_pass=$f2p_any_pass"
echo "REWARD=$(cat "$REWARD_FILE")"
