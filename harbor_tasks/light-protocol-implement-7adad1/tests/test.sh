#!/usr/bin/env bash
# ============================================================================
# Harbor verifier — light-protocol-implement-7adad1
#
# Upstream CI source:
#   .github/workflows/sdk-tests.yml — cargo-test-sbf (integration)
#   .github/workflows/rust.yml       — just program-libs test-fast (unit)
#   Session uses: cargo test -p light-sdk-macros
# ============================================================================
set -euo pipefail

REPO="/home/user/light-protocol"
REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
WORKDIR="/workspace"

mkdir -p "$(dirname "$REWARD_FILE")" "$(dirname "$GATES_FILE")"

# ---------------------------------------------------------------------------
# Python verifier for Rust AST checks using tree-sitter
# ---------------------------------------------------------------------------
run_python_verifier() {
    python3 - "$@" << 'PYEOF'
import sys
import json

try:
    from tree_sitter import Language, Parser
    import tree_sitter_rust
    RUST_LANG = Language(tree_sitter_rust.language())
    PARSER = Parser(RUST_LANG)
except ImportError as e:
    print(f"FATAL: tree-sitter not available: {e}", file=sys.stderr)
    sys.exit(1)

def parse_file(path):
    """Parse a Rust source file, return root node."""
    try:
        with open(path, "rb") as f:
            source = f.read()
    except FileNotFoundError:
        return None, None
    tree = PARSER.parse(source)
    return tree, source

def find_struct_field(struct_node, source, field_name):
    """Check if a struct has a field with the given name and return (has_field, field_type)."""
    for child in struct_node.children:
        if child.type == "field_declaration_list":
            for decl in child.children:
                if decl.type == "field_declaration":
                    name_node = None
                    type_node = None
                    for fc in decl.children:
                        if fc.type == "field_identifier":
                            name_node = fc
                        elif fc.type == "type_identifier":
                            type_node = fc
                        elif fc.type == "primitive_type":
                            type_node = fc
                    if name_node is not None:
                        fname = source[name_node.start_byte:name_node.end_byte].decode()
                        if fname == field_name:
                            ftype = ""
                            if type_node is not None:
                                ftype = source[type_node.start_byte:type_node.end_byte].decode()
                            return True, ftype
    return False, ""

def find_struct_in_file(path, struct_name):
    """Find a struct definition by name."""
    tree, source = parse_file(path)
    if tree is None:
        return None, None
    cursor = tree.walk()
    stack = [cursor.node]
    while stack:
        node = stack.pop()
        if node.type == "struct_item":
            for child in node.children:
                if child.type == "type_identifier":
                    sname = source[child.start_byte:child.end_byte].decode()
                    if sname == struct_name:
                        return node, source
        for child in node.children:
            stack.append(child)
    return None, None

def find_const_array_entry(path, const_name, entry):
    """Check if a const array contains a specific string literal."""
    tree, source = parse_file(path)
    if tree is None:
        return False
    cursor = tree.walk()
    stack = [cursor.node]

    # Find the const item
    for node in _iter_nodes(tree.root_node):
        if node.type == "const_item":
            for child in node.children:
                if child.type == "identifier":
                    cname = source[child.start_byte:child.end_byte].decode()
                    if cname == const_name:
                        # Walk all descendants looking for string literals
                        for desc in _iter_nodes(node):
                            if desc.type == "string_literal":
                                val = source[desc.start_byte:desc.end_byte].decode()
                                if val.strip('"') == entry:
                                    return True
    return False

def _iter_nodes(root):
    """Iterate all nodes in DFS order."""
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        for child in node.children:
            stack.append(child)

def find_token_by_name(root, source, kind, name):
    """Find a node of given kind with given name."""
    for node in _iter_nodes(root):
        if node.type == kind:
            for child in node.children:
                if child.type == "identifier":
                    cname = source[child.start_byte:child.end_byte].decode()
                    if cname == name:
                        return node
    return None

def find_function(path, func_name):
    """Check if a function exists in a file."""
    tree, source = parse_file(path)
    if tree is None:
        return False
    for node in _iter_nodes(tree.root_node):
        if node.type == "function_item":
            for child in node.children:
                if child.type == "identifier":
                    fname = source[child.start_byte:child.end_byte].decode()
                    if fname == func_name:
                        return True
    return False

def check_atafield_has_idempotent():
    """Verify AtaField struct has idempotent: bool field."""
    struct_node, source = find_struct_in_file(
        f"{sys.argv[1]}/sdk-libs/macros/src/light_pdas/accounts/light_account.rs",
        "AtaField"
    )
    if struct_node is None:
        print("FAIL: AtaField struct not found")
        return False
    has_field, ftype = find_struct_field(struct_node, source, "idempotent")
    if not has_field:
        print("FAIL: AtaField missing 'idempotent' field")
        return False
    if ftype != "bool":
        print(f"FAIL: AtaField.idempotent has type '{ftype}', expected 'bool'")
        return False
    print("PASS: AtaField has idempotent: bool")
    return True

def check_keywords_has_idempotent():
    """Verify ASSOCIATED_TOKEN_NAMESPACE_KEYS contains 'idempotent'."""
    result = find_const_array_entry(
        f"{sys.argv[1]}/sdk-libs/macros/src/light_pdas/light_account_keywords.rs",
        "ASSOCIATED_TOKEN_NAMESPACE_KEYS",
        "idempotent"
    )
    if not result:
        print("FAIL: ASSOCIATED_TOKEN_NAMESPACE_KEYS missing 'idempotent'")
        return False
    print("PASS: ASSOCIATED_TOKEN_NAMESPACE_KEYS contains 'idempotent'")
    return True

def check_boolean_flag_system():
    """Verify BOOLEAN_FLAG_KEYS_BY_NAMESPACE and is_boolean_flag_key exist."""
    path = f"{sys.argv[1]}/sdk-libs/macros/src/light_pdas/light_account_keywords.rs"
    tree, source = parse_file(path)
    if tree is None:
        print("FAIL: cannot parse keywords file")
        return False

    has_const = find_token_by_name(tree.root_node, source, "identifier", "BOOLEAN_FLAG_KEYS_BY_NAMESPACE")
    if has_const is None:
        print("FAIL: BOOLEAN_FLAG_KEYS_BY_NAMESPACE not found")
        return False

    has_fn = find_function(path, "is_boolean_flag_key")
    if not has_fn:
        print("FAIL: is_boolean_flag_key function not found")
        return False

    print("PASS: BOOLEAN_FLAG_KEYS_BY_NAMESPACE and is_boolean_flag_key exist")
    return True

def check_builder_uses_idempotent():
    """Verify the ATA codegen uses the idempotent field (no longer hardcoded true)."""
    token_path = f"{sys.argv[1]}/sdk-libs/macros/src/light_pdas/accounts/token.rs"
    tree, source = parse_file(token_path)
    if tree is None:
        print("FAIL: cannot parse token.rs")
        return False

    # The change should either:
    # a) Remove/replace the hardcoded .idempotent() call with conditional logic, OR
    # b) Use field.idempotent somewhere in the ATA generation code
    #
    # Check: the generate_pre_init_token_creation code should reference
    # idempotent via a variable (not hardcoded .idempotent())
    source_str = source.decode()
    has_field_ref = "field.idempotent" in source_str or "idempotent_val" in source_str
    if not has_field_ref:
        print("FAIL: ATA codegen does not reference field.idempotent (still hardcoded?)")
        return False
    print("PASS: ATA codegen references the idempotent field")
    return True

def check_non_idempotent_file():
    """Verify the new non-idempotent accounts file exists and looks reasonable."""
    import os
    path = f"{sys.argv[1]}/sdk-tests/csdk-anchor-full-derived-test/src/instructions/d10_token_accounts/single_ata_non_idempotent.rs"
    if not os.path.exists(path):
        print("FAIL: single_ata_non_idempotent.rs not found")
        return False
    # Verify it has a struct
    tree, source = parse_file(path)
    if tree is None:
        print("FAIL: cannot parse new file")
        return False
    has_struct = any(n.type == "struct_item" for n in _iter_nodes(tree.root_node))
    if not has_struct:
        print("FAIL: single_ata_non_idempotent.rs has no struct definition")
        return False
    print("PASS: single_ata_non_idempotent.rs exists with struct definition")
    return True

if __name__ == "__main__":
    cmd = sys.argv[2] if len(sys.argv) > 2 else ""
    repo = sys.argv[1]
    if cmd == "atafield-idempotent":
        sys.exit(0 if check_atafield_has_idempotent() else 1)
    elif cmd == "keywords-idempotent":
        sys.exit(0 if check_keywords_has_idempotent() else 1)
    elif cmd == "boolean-flag-system":
        sys.exit(0 if check_boolean_flag_system() else 1)
    elif cmd == "builder-uses-idempotent":
        sys.exit(0 if check_builder_uses_idempotent() else 1)
    elif cmd == "non-idempotent-file":
        sys.exit(0 if check_non_idempotent_file() else 1)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# Gate verdicts
# ---------------------------------------------------------------------------
declare -A VERDICTS
declare -A GATE_KINDS
GATE_ORDER=()

emit_gate() {
    local gid="$1"
    local kind="$2"
    local passed="$3"
    VERDICTS["$gid"]="$passed"
    GATE_KINDS["$gid"]="$kind"
    GATE_ORDER+=("$gid")
}

# ---- F2P Gate 1: AtaField has idempotent: bool (tree-sitter AST) ----
if run_python_verifier "$REPO" "atafield-idempotent"; then
    emit_gate "atafield-idempotent" "F2P" "true"
else
    emit_gate "atafield-idempotent" "F2P" "false"
fi

# ---- F2P Gate 2: cargo test -p light-sdk-macros compiles & passes ----
cd "$REPO"
if cargo test -p light-sdk-macros --no-fail-fast 2>&1 | tail -20; then
    MACRO_TESTS_PASSED=true
else
    MACRO_TESTS_PASSED=false
fi
if [ "$MACRO_TESTS_PASSED" = "true" ]; then
    emit_gate "compile-macros" "F2P" "true"
else
    emit_gate "compile-macros" "F2P" "false"
fi

# ---- F2P Gate 3: ASSOCIATED_TOKEN_NAMESPACE_KEYS has "idempotent" ----
if run_python_verifier "$REPO" "keywords-idempotent"; then
    emit_gate "keywords-idempotent" "F2P" "true"
else
    emit_gate "keywords-idempotent" "F2P" "false"
fi

# ---- F2P Gate 4: BOOLEAN_FLAG_KEYS_BY_NAMESPACE + is_boolean_flag_key ----
if run_python_verifier "$REPO" "boolean-flag-system"; then
    emit_gate "boolean-flag-system" "F2P" "true"
else
    emit_gate "boolean-flag-system" "F2P" "false"
fi

# ---- F2P Gate 5: Builder/token codegen uses idempotent field ----
if run_python_verifier "$REPO" "builder-uses-idempotent"; then
    emit_gate "builder-uses-idempotent" "F2P" "true"
else
    emit_gate "builder-uses-idempotent" "F2P" "false"
fi

# ---- F2P Gate 6: New non-idempotent file exists ----
if run_python_verifier "$REPO" "non-idempotent-file"; then
    emit_gate "non-idempotent-file" "F2P" "true"
else
    emit_gate "non-idempotent-file" "F2P" "false"
fi

# ---- P2P_REGRESSION: AtaField still has original fields ----
P2P_FAILED=false
ATA_FIELD_FILE="$REPO/sdk-libs/macros/src/light_pdas/accounts/light_account.rs"
python3 -c "
import sys
from tree_sitter import Language, Parser
import tree_sitter_rust
RUST_LANG = Language(tree_sitter_rust.language())
PAR = Parser(RUST_LANG)
with open('$ATA_FIELD_FILE', 'rb') as f:
    src = f.read()
tree = PAR.parse(src)
root = tree.root_node

# Find AtaField struct
def iter_nodes(n):
    stack = [n]
    while stack:
        node = stack.pop()
        yield node
        for c in node.children:
            stack.append(c)

found = False
required = {'field_ident', 'has_init', 'owner', 'mint'}
for node in iter_nodes(root):
    if node.type == 'struct_item':
        for child in node.children:
            if child.type == 'type_identifier':
                if src[child.start_byte:child.end_byte].decode() == 'AtaField':
                    found = True
                    # Collect field names
                    seen = set()
                    for fc in node.children:
                        if fc.type == 'field_declaration_list':
                            for decl in fc.children:
                                if decl.type == 'field_declaration':
                                    for dc in decl.children:
                                        if dc.type == 'field_identifier':
                                            seen.add(src[dc.start_byte:dc.end_byte].decode())
                    missing = required - seen
                    if missing:
                        print(f'P2P FAIL: AtaField missing original fields: {missing}')
                        sys.exit(1)
                    else:
                        print('P2P PASS: AtaField retains original fields')
                        sys.exit(0)
if not found:
    print('P2P FAIL: AtaField struct not found')
    sys.exit(1)
print('P2P PASS: AtaField struct found with all original fields intact')
" || P2P_FAILED=true

emit_gate "atafield-regression" "P2P_REGRESSION" "$([ "$P2P_FAILED" = "false" ] && echo "true" || echo "false")"

# ===========================================================================
# Reward calculation — weighted-replace formula (Harbor c8bc168a)
# ===========================================================================
# F2P weights (must sum ≤ 1.0)
declare -A WEIGHTS
WEIGHTS["atafield-idempotent"]="0.25"
WEIGHTS["compile-macros"]="0.25"
WEIGHTS["keywords-idempotent"]="0.15"
WEIGHTS["boolean-flag-system"]="0.15"
WEIGHTS["builder-uses-idempotent"]="0.10"
WEIGHTS["non-idempotent-file"]="0.10"

# Check if any P2P gate failed
p2p_failed="false"
for gid in "${GATE_ORDER[@]}"; do
    if [ "${GATE_KINDS[$gid]}" = "P2P_REGRESSION" ] && [ "${VERDICTS[$gid]}" = "false" ]; then
        p2p_failed="true"
        break
    fi
done

# Check if any F2P gate passed
f2p_any_pass="false"
for gid in "${GATE_ORDER[@]}"; do
    if [ "${GATE_KINDS[$gid]}" = "F2P" ] && [ "${VERDICTS[$gid]}" = "true" ]; then
        f2p_any_pass="true"
        break
    fi
done

# Compute reward
reward=0.0
if [ "$p2p_failed" = "true" ] || [ "$f2p_any_pass" = "false" ]; then
    reward=0.0
else
    # Compute inner_weight = max(0, 1.0 - sum(WEIGHTS))
    weights_sum=0.0
    for gid in "${!WEIGHTS[@]}"; do
        weights_sum=$(echo "$weights_sum + ${WEIGHTS[$gid]}" | bc -l)
    done
    inner_weight=$(echo "1.0 - $weights_sum" | bc -l)
    if [ "$(echo "$inner_weight < 0" | bc -l)" = "1" ]; then
        inner_weight=0.0
    fi

    existing=1.0
    reward=$(echo "$existing * $inner_weight" | bc -l)

    for gid in "${!WEIGHTS[@]}"; do
        if [ "${VERDICTS[$gid]}" = "true" ]; then
            reward=$(echo "$reward + ${WEIGHTS[$gid]}" | bc -l)
        fi
    done
fi

# Clamp to [0, 1]
if [ "$(echo "$reward > 1.0" | bc -l)" = "1" ]; then
    reward=1.0
fi
if [ "$(echo "$reward < 0.0" | bc -l)" = "1" ]; then
    reward=0.0
fi

# Write results
echo "$reward" > "$REWARD_FILE"

# Write gates JSON
echo "{" > "$GATES_FILE"
first=true
for gid in "${GATE_ORDER[@]}"; do
    if [ "$first" = "true" ]; then
        first=false
    else
        echo "," >> "$GATES_FILE"
    fi
    printf '  "%s": {"passed": %s, "kind": "%s"}' \
        "$gid" "${VERDICTS[$gid]}" "${GATE_KINDS[$gid]}" >> "$GATES_FILE"
done
echo "" >> "$GATES_FILE"
echo "}" >> "$GATES_FILE"

echo "Reward: $reward"
echo "Gates: $(cat "$GATES_FILE")"
