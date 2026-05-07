#!/usr/bin/env bash
# =============================================================================
# CI/CD source: .github/workflows/verify.yml (Mathews-Tom/no-magic)
#
# Upstream checks:
#   1. python -m py_compile on all 0[1-4]-*/*.py scripts
#   2. random.seed(42) present in micro*.py
#   3. No imports outside stdlib + allowed modules
#   4. Full run: timeout 900 python <script> (workflow_dispatch only)
#
# This harness adapts those checks into F2P behavioral gates with
# weighted-replace reward accumulation.
# =============================================================================

set +e

REPO_DIR="/home/user/no-magic"
TARGET="$REPO_DIR/01-foundations/microtokenizer.py"
REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"

mkdir -p /logs/verifier
echo "0.0" > "$REWARD_FILE"
echo '{}' > "$GATES_FILE"

# ---------------------------------------------------------------------------
# Helper: emit gate verdict into gates.json
# ---------------------------------------------------------------------------
emit_gate() {
    local gid="$1"
    local passed="$2"
    python3 -c "
import json, os
gf = '$GATES_FILE'
data = json.load(open(gf)) if os.path.exists(gf) else {}
data['$gid'] = ('$passed' == 'true')
json.dump(data, open(gf, 'w'))
"
}

# ---------------------------------------------------------------------------
# P2P_REGRESSION gates: must pass or reward = 0
# ---------------------------------------------------------------------------
P2P_FAILED=false

# P2P: File must exist
if [ ! -f "$TARGET" ]; then
    echo "[P2P_REGRESSION] FAIL: $TARGET not found"
    P2P_FAILED=true
else
    echo "[P2P_REGRESSION] PASS: $TARGET exists"
fi

# P2P: Anti-stub — file must have >= 80 lines (not a trivial placeholder)
LINE_COUNT=$(wc -l < "$TARGET" 2>/dev/null || echo 0)
if [ "$LINE_COUNT" -lt 80 ]; then
    echo "[P2P_REGRESSION] FAIL: $TARGET has $LINE_COUNT lines (< 80, likely a stub)"
    P2P_FAILED=true
else
    echo "[P2P_REGRESSION] PASS: $TARGET has $LINE_COUNT lines"
fi

# P2P: AST anti-stub — at least 3 functions must have body depth > 3 statements
AST_STUB_CHECK=$(python3 -c "
import ast, sys
try:
    tree = ast.parse(open('$TARGET').read())
except SyntaxError:
    print('SYNTAX_ERROR')
    sys.exit(0)

def body_depth(node):
    if not hasattr(node, 'body'):
        return 0
    stmts = [s for s in node.body if not isinstance(s, (ast.Expr, ast.Pass))]
    return len(stmts)

funcs = [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
deep = [f.name for f in funcs if body_depth(f) > 3]
if len(deep) >= 3:
    print('PASS:' + ','.join(deep))
else:
    print('FAIL:only ' + str(len(deep)) + ' functions with body > 3 statements (need >=3)')
")
if echo "$AST_STUB_CHECK" | grep -q "^PASS:"; then
    echo "[P2P_REGRESSION] PASS: AST anti-stub — $AST_STUB_CHECK"
else
    echo "[P2P_REGRESSION] FAIL: AST anti-stub — $AST_STUB_CHECK"
    P2P_FAILED=true
fi

# ---------------------------------------------------------------------------
# If any P2P_REGRESSION failed, write 0 and exit
# ---------------------------------------------------------------------------
if $P2P_FAILED; then
    echo "0.0" > "$REWARD_FILE"
    echo "P2P_REGRESSION failed — reward=0.0"
    exit 0
fi

# ---------------------------------------------------------------------------
# F2P gates: behavioral correctness checks
#
# Gate design:
#   gate_syntax      (0.10) — python -m py_compile passes
#   gate_executes    (0.20) — script runs, exit 0, within 120s
#   gate_roundtrip   (0.25) — all 6 round-trip tests show [PASS]
#   gate_compression (0.20) — compression ratio >= 1.5x
#   gate_training    (0.15) — training output shows >= 8 merge progress lines
#   gate_stdlib      (0.10) — no non-stdlib imports (AST verified)
# Total = 1.00
#
# Behavioral: gate_executes(0.20) + gate_roundtrip(0.25) +
#             gate_compression(0.20) + gate_training(0.15) = 0.80 (80%)
# Structural: gate_syntax(0.10) + gate_stdlib(0.10) = 0.20 (20%)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# F2P gate: gate_syntax (0.10)
# ---------------------------------------------------------------------------
echo ""
echo "=== gate_syntax ==="
cd "$REPO_DIR"
if python3 -m py_compile "$TARGET" 2>/dev/null; then
    echo "PASS: syntax check passed"
    emit_gate "gate_syntax" "true"
else
    echo "FAIL: syntax check failed"
    emit_gate "gate_syntax" "false"
fi

# ---------------------------------------------------------------------------
# F2P gate: gate_executes (0.20)
# ---------------------------------------------------------------------------
echo ""
echo "=== gate_executes ==="
cd "$REPO_DIR"
SCRIPT_OUTPUT=$(mktemp /tmp/microtokenizer_output.XXXXXX)
if timeout 120 python3 "$TARGET" > "$SCRIPT_OUTPUT" 2>&1; then
    echo "PASS: script ran successfully (exit 0)"
    emit_gate "gate_executes" "true"
else
    EXIT_CODE=$?
    echo "FAIL: script timed out or failed (exit=$EXIT_CODE)"
    emit_gate "gate_executes" "false"
fi

# ---------------------------------------------------------------------------
# F2P gate: gate_roundtrip (0.25)
# ---------------------------------------------------------------------------
echo ""
echo "=== gate_roundtrip ==="
cd "$REPO_DIR"
PASS_COUNT=$(grep -c '\[PASS\]' "$SCRIPT_OUTPUT" 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c '\[FAIL\]' "$SCRIPT_OUTPUT" 2>/dev/null || echo 0)
echo "Round-trip results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"

if [ "$PASS_COUNT" -ge 6 ] && [ "$FAIL_COUNT" -eq 0 ]; then
    echo "PASS: all 6 round-trip tests passed"
    emit_gate "gate_roundtrip" "true"
else
    echo "FAIL: expected 6 PASS, 0 FAIL; got $PASS_COUNT PASS, $FAIL_COUNT FAIL"
    emit_gate "gate_roundtrip" "false"
fi

# ---------------------------------------------------------------------------
# F2P gate: gate_compression (0.20)
# ---------------------------------------------------------------------------
echo ""
echo "=== gate_compression ==="
cd "$REPO_DIR"
RATIO=$(grep -oP 'ratio:\s*\K[\d.]+(?=x)' "$SCRIPT_OUTPUT" 2>/dev/null || echo "0")
echo "Compression ratio: ${RATIO}x"

if python3 -c "exit(0 if float('$RATIO' or '0') >= 1.5 else 1)"; then
    echo "PASS: compression ratio ${RATIO}x >= 1.5x"
    emit_gate "gate_compression" "true"
else
    echo "FAIL: compression ratio ${RATIO}x < 1.5x"
    emit_gate "gate_compression" "false"
fi

# ---------------------------------------------------------------------------
# F2P gate: gate_training (0.15)
# ---------------------------------------------------------------------------
echo ""
echo "=== gate_training ==="
cd "$REPO_DIR"
MERGE_LINES=$(grep -c 'merge\s\+[0-9]\+/' "$SCRIPT_OUTPUT" 2>/dev/null || echo 0)
echo "Merge progress lines: $MERGE_LINES"

if [ "$MERGE_LINES" -ge 8 ]; then
    echo "PASS: $MERGE_LINES merge progress lines (>= 8)"
    emit_gate "gate_training" "true"
else
    echo "FAIL: only $MERGE_LINES merge progress lines (< 8)"
    emit_gate "gate_training" "false"
fi

# ---------------------------------------------------------------------------
# F2P gate: gate_stdlib (0.10)
# ---------------------------------------------------------------------------
echo ""
echo "=== gate_stdlib ==="
cd "$REPO_DIR"
STDLIB_RESULT=$(python3 -c "
import ast, sys

STDLIB = {
    'os', 'math', 'random', 'json', 'struct', 'urllib', 'collections',
    'itertools', 'functools', 'string', 'hashlib', 'time', 'sys',
    'argparse', 'textwrap', 'io', 'copy', 'abc', 'typing', 're',
    'pathlib', 'enum', 'dataclasses', 'contextlib', 'warnings',
    'urllib.request', 'urllib.error', 'urllib.parse',
    'collections.abc', '__future__',
}

try:
    tree = ast.parse(open('$TARGET').read())
except SyntaxError:
    print('SYNTAX_ERROR')
    sys.exit(0)

bad = []
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            mod = alias.name.split('.')[0]
            if mod not in STDLIB and alias.name not in STDLIB:
                bad.append(alias.name)
    elif isinstance(node, ast.ImportFrom):
        if node.module:
            mod = node.module.split('.')[0]
            if mod not in STDLIB and node.module not in STDLIB:
                bad.append(node.module)

if bad:
    print('FAIL:' + ','.join(bad))
else:
    print('PASS')
")

if echo "$STDLIB_RESULT" | grep -q "^PASS"; then
    echo "PASS: no external imports"
    emit_gate "gate_stdlib" "true"
else
    echo "FAIL: external imports found — $STDLIB_RESULT"
    emit_gate "gate_stdlib" "false"
fi

# ---------------------------------------------------------------------------
# Accumulate reward via weighted-replace formula
# ---------------------------------------------------------------------------
echo ""
echo "=== Reward Accumulation ==="

python3 << 'PYEOF'
import json, os

REWARD_FILE = "/logs/verifier/reward.txt"
GATES_FILE = "/logs/verifier/gates.json"

WEIGHTS = {
    "gate_syntax": 0.10,
    "gate_executes": 0.20,
    "gate_roundtrip": 0.25,
    "gate_compression": 0.20,
    "gate_training": 0.15,
    "gate_stdlib": 0.10,
}

verdicts = {}
if os.path.exists(GATES_FILE):
    verdicts = json.load(open(GATES_FILE))

# Read base reward
existing = 0.0
if os.path.exists(REWARD_FILE):
    try:
        existing = float(open(REWARD_FILE).read().strip())
    except ValueError:
        existing = 0.0

# Check if any F2P gate passed
f2p_any_pass = any(verdicts.get(gid) for gid in WEIGHTS)

# Check if any P2P gate failed (P2P_FAILED env var)
p2p_failed = os.environ.get("P2P_FAILED", "false") == "true"

if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)

reward = min(reward, 1.0)
reward = max(reward, 0.0)

with open(REWARD_FILE, "w") as f:
    f.write(f"{reward:.6f}\n")

print(f"Final reward: {reward:.6f}")
print(f"Gate verdicts: {json.dumps(verdicts, indent=2)}")

# Write final state to gates.json
with open(GATES_FILE, "w") as f:
    json.dump({"verdicts": verdicts, "reward": reward}, f, indent=2)
PYEOF

# Clean up temp file
rm -f "$SCRIPT_OUTPUT"

echo ""
echo "Reward written to $REWARD_FILE"
cat "$REWARD_FILE"
