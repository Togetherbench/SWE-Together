#!/usr/bin/env bash
# CI source: upstream uses `mise run lint` (lint.yml) and `mise run test:ci` (ci.yml)
# This test suite verifies the mise lint script correctly detects indented
# multi-line run blocks in mise.toml after the awk pattern fix.
set +e

REPO="/opt/cli"
LINT_SCRIPT="$REPO/mise-tasks/lint/mise"
REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
TMPDIR=$(mktemp -d)

# Cleanup
rm -f "$GATES_FILE"
echo "0.0" > "$REWARD_FILE"
> "$GATES_FILE"

emit_gate() {
    local gid="$1" verdict="$2"
    printf '{"id":"%s","verdict":"%s"}\n' "$gid" "$verdict" >> "$GATES_FILE"
}

# ---- P2P REGRESSION GATES (must pass; zero on fail) ----

# P2P_1: The mise lint file must exist
if [ -f "$LINT_SCRIPT" ]; then
    emit_gate "p2p_file_exists" "pass"
else
    emit_gate "p2p_file_exists" "fail"
fi

# P2P_2: Agent must have made changes to the file
cd "$REPO"
if git diff --name-only HEAD | grep -q "mise-tasks/lint/mise"; then
    emit_gate "p2p_agent_modified" "pass"
else
    # Also check staged changes
    if git diff --cached --name-only | grep -q "mise-tasks/lint/mise"; then
        emit_gate "p2p_agent_modified" "pass"
    else
        emit_gate "p2p_agent_modified" "fail"
    fi
fi

# P2P_3: The script is syntactically valid shell (check with sh -n)
if sh -n "$LINT_SCRIPT" 2>/dev/null; then
    emit_gate "p2p_valid_shell" "pass"
else
    emit_gate "p2p_valid_shell" "fail"
fi

# ---- F2P BEHAVIORAL GATES (contribute to reward) ----

# F2P_G1: Detects indented multi-line run blocks (>3 lines) in triple-double-quote syntax
mkdir -p "$TMPDIR/g1"
cat > "$TMPDIR/g1/mise.toml" << 'TOML'
[tools]
go = "1.26.0"

[tasks.test_indented]
description = "Test indented multi-line block"
    run = """
echo line one
echo line two
echo line three
echo line four
    """
TOML
G1_OUT=$(cd "$TMPDIR/g1" && bash "$LINT_SCRIPT" 2>&1)
G1_RC=$?
if [ $G1_RC -ne 0 ]; then
    emit_gate "g1_indented_detection" "pass"
else
    emit_gate "g1_indented_detection" "fail"
fi

# F2P_G2: Does NOT flag short inline scripts (<=3 content lines, no false positives)
mkdir -p "$TMPDIR/g2"
cat > "$TMPDIR/g2/mise.toml" << 'TOML'
[tools]
go = "1.26.0"

[tasks.short]
description = "Short inline script"
run = """
echo one
echo two
echo three
"""
TOML
G2_OUT=$(cd "$TMPDIR/g2" && bash "$LINT_SCRIPT" 2>&1)
G2_RC=$?
if [ $G2_RC -eq 0 ]; then
    emit_gate "g2_short_no_fp" "pass"
else
    emit_gate "g2_short_no_fp" "fail"
fi

# F2P_G3: Handles single-quote triple syntax (''') with indentation
mkdir -p "$TMPDIR/g3"
cat > "$TMPDIR/g3/mise.toml" << 'TOML'
[tools]
go = "1.26.0"

[tasks.test_single_quote]
description = "Single-quote indented test"
    run = '''
echo L1
echo L2
echo L3
echo L4
    '''
TOML
G3_OUT=$(cd "$TMPDIR/g3" && bash "$LINT_SCRIPT" 2>&1)
G3_RC=$?
if [ $G3_RC -ne 0 ]; then
    emit_gate "g3_single_quote_syntax" "pass"
else
    emit_gate "g3_single_quote_syntax" "fail"
fi

# F2P_G4: Regression — still detects non-indented multi-line blocks (>3 lines)
mkdir -p "$TMPDIR/g4"
cat > "$TMPDIR/g4/mise.toml" << 'TOML'
[tools]
go = "1.26.0"

[tasks.test_non_indented]
description = "Non-indented multi-line block"
run = """
echo L1
echo L2
echo L3
echo L4
"""
TOML
G4_OUT=$(cd "$TMPDIR/g4" && bash "$LINT_SCRIPT" 2>&1)
G4_RC=$?
if [ $G4_RC -ne 0 ]; then
    emit_gate "g4_non_indented_still_works" "pass"
else
    emit_gate "g4_non_indented_still_works" "fail"
fi

# F2P_G5: Closing delimiter is NOT counted in reported line count
# A block with 5 content lines + closing delimiter should report "5 lines", not "6"
mkdir -p "$TMPDIR/g5"
cat > "$TMPDIR/g5/mise.toml" << 'TOML'
[tools]
go = "1.26.0"

[tasks.test_line_count]
description = "Line count test"
    run = """
line_a
line_b
line_c
line_d
line_e
    """
TOML
G5_OUT=$(cd "$TMPDIR/g5" && bash "$LINT_SCRIPT" 2>&1)
G5_RC=$?
# Check that output reports "5 lines" not "6 lines" (if detected)
if [ $G5_RC -ne 0 ]; then
    if echo "$G5_OUT" | grep -q "(5 lines)"; then
        emit_gate "g5_line_count_excludes_delimiter" "pass"
    elif echo "$G5_OUT" | grep -q "(6 lines)"; then
        emit_gate "g5_line_count_excludes_delimiter" "fail"
    else
        # Detected but with unexpected count format — check it doesn't say 6
        if ! echo "$G5_OUT" | grep -q "(6 lines)"; then
            emit_gate "g5_line_count_excludes_delimiter" "pass"
        else
            emit_gate "g5_line_count_excludes_delimiter" "fail"
        fi
    fi
else
    # If it doesn't detect at all (shouldn't happen with 5 content lines > 3)
    emit_gate "g5_line_count_excludes_delimiter" "fail"
fi

# ---- COMPUTE REWARD ----

# Check P2P gates: any failure => reward = 0.0
P2P_FAILED=false
for gid in p2p_file_exists p2p_agent_modified p2p_valid_shell; do
    if grep -q "\"id\":\"$gid\",\"verdict\":\"fail\"" "$GATES_FILE" 2>/dev/null; then
        P2P_FAILED=true
        break
    fi
done

if $P2P_FAILED; then
    echo "0.0" > "$REWARD_FILE"
    echo "P2P gate failure — reward set to 0.0"
    rm -rf "$TMPDIR"
    exit 0
fi

# Weighted-replace reward formula
WEIGHTS='{"g1_indented_detection":0.20,"g2_short_no_fp":0.15,"g3_single_quote_syntax":0.15,"g4_non_indented_still_works":0.10,"g5_line_count_excludes_delimiter":0.10}'

# Determine which F2P gates passed
F2P_ANY_PASS=false
declare -A VERDICTS
while IFS= read -r line; do
    gid=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")
    verdict=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['verdict'])")
    VERDICTS["$gid"]="$verdict"
done < "$GATES_FILE"

# Check if any F2P gate passed
for gid in g1_indented_detection g2_short_no_fp g3_single_quote_syntax g4_non_indented_still_works g5_line_count_excludes_delimiter; do
    if [ "${VERDICTS[$gid]}" = "pass" ]; then
        F2P_ANY_PASS=true
        break
    fi
done

if ! $F2P_ANY_PASS; then
    echo "0.0" > "$REWARD_FILE"
    echo "No F2P gates passed — reward set to 0.0"
    rm -rf "$TMPDIR"
    exit 0
fi

# Compute reward with weighted-replace
python3 << 'PYEOF'
import json

with open("/logs/verifier/gates.json") as f:
    lines = [json.loads(l) for l in f if l.strip()]

verdicts = {d["id"]: d["verdict"] for d in lines}

weights = json.loads('''{"g1_indented_detection":0.20,"g2_short_no_fp":0.15,"g3_single_quote_syntax":0.15,"g4_non_indented_still_works":0.10,"g5_line_count_excludes_delimiter":0.10}''')

# Check P2P gates
p2p_failed = any(
    verdicts.get(gid) == "fail"
    for gid in ["p2p_file_exists", "p2p_agent_modified", "p2p_valid_shell"]
)

# Check if any F2P gate passed
f2p_any_pass = any(
    verdicts.get(gid) == "pass"
    for gid in weights
)

if p2p_failed or not f2p_any_pass:
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(weights.values()))
    reward = 0.0 * inner_weight  # existing = 0.0 initially
    for gid, w in weights.items():
        if verdicts.get(gid) == "pass":
            reward += float(w)

with open("/logs/verifier/reward.txt", "w") as f:
    f.write(str(reward))
PYEOF

rm -rf "$TMPDIR"
