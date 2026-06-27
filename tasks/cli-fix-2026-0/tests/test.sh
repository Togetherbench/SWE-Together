#!/bin/bash
# ==========================================================================
# CI/CD source: .github/workflows/ci.yml (mise run test) and lint.yml
# Canonical test command: go test ./cmd/entire/cli/strategy/...
# Build check:          go build ./cmd/entire/cli/strategy/...
# ==========================================================================
set +e


# Canonical PATH (E2B strips Dockerfile ENV PATH; restore tool dirs)
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO_DIR="/workspace/repo"
STRATEGY_DIR="$REPO_DIR/cmd/entire/cli/strategy"
GATES_FILE="/logs/verifier/gates.json"
REWARD_FILE="/logs/verifier/reward.txt"

mkdir -p /logs/verifier

# ------------------------------------------------------------------
# Helper: emit a gate verdict
# ------------------------------------------------------------------
verdicts_json="{}"

emit_gate() {
    local gid="$1"
    local pass="$2"
    # Normalize bash-style true/false to Python True/False so the heredoc is
    # valid Python source (bare `true` is a NameError; this used to silently
    # blank out verdicts_json and cascade JSONDecodeError on every subsequent
    # call, leaving gates.json a single newline and reward.txt unwritten).
    local py_bool
    case "$pass" in
        true|True|TRUE|1) py_bool="True" ;;
        *) py_bool="False" ;;
    esac
    local new_json
    new_json=$(echo "$verdicts_json" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
d['$gid'] = $py_bool
print(json.dumps(d))
")
    if [ -n "$new_json" ]; then
        verdicts_json="$new_json"
    fi
}

# ------------------------------------------------------------------
# Write a Go AST checker script (reusable runner)
# ------------------------------------------------------------------
mkdir -p /tmp/ast_check_runner_pkg
cat > /tmp/ast_check_runner_pkg/main.go << 'GOEOF'
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: ast_check_runner <file> <check_name>")
		os.Exit(1)
	}
	filePath := os.Args[1]
	checkName := os.Args[2]

	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filePath, nil, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "PARSE_ERROR: %v\n", err)
		os.Exit(1)
	}

	switch checkName {
	case "debug_logs":
		checkDebugLogs(f)
	case "no_getfilecontent_in_diff":
		checkNoGetFileContentInDiff(f)
	case "checkpoint_guard_removed":
		checkCheckpointGuardRemoved(f)
	default:
		fmt.Fprintf(os.Stderr, "UNKNOWN_CHECK: %s\n", checkName)
		os.Exit(1)
	}
}

// checkDebugLogs verifies that calculatePromptAttributionAtStart contains
// logging.Debug calls — the primary instruction from the user.
func checkDebugLogs(f *ast.File) {
	var fn *ast.FuncDecl
	ast.Inspect(f, func(n ast.Node) bool {
		if fd, ok := n.(*ast.FuncDecl); ok {
			if fd.Recv != nil && len(fd.Recv.List) > 0 {
				if fd.Name.Name == "calculatePromptAttributionAtStart" {
					fn = fd
					return false
				}
			}
		}
		return true
	})

	if fn == nil {
		fmt.Println("FAIL: calculatePromptAttributionAtStart method not found")
		os.Exit(2)
	}

	debugCount := 0
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		selName := sel.Sel.Name
		if selName != "Debug" && selName != "DebugContext" {
			return true
		}
		ident, ok := sel.X.(*ast.Ident)
		if !ok {
			return true
		}
		if ident.Name == "logging" {
			debugCount++
		}
		return true
	})

	if debugCount >= 1 {
		fmt.Printf("PASS: found %d logging.Debug call(s) in calculatePromptAttributionAtStart\n", debugCount)
	} else {
		fmt.Println("FAIL: no logging.Debug calls in calculatePromptAttributionAtStart")
		os.Exit(3)
	}
}

// checkNoGetFileContentInDiff verifies that getAllChangedFilesBetweenTrees
// does NOT call getFileContent — indicating the performance optimization
// was applied (hash-based comparison instead of content-based).
func checkNoGetFileContentInDiff(f *ast.File) {
	var fn *ast.FuncDecl
	ast.Inspect(f, func(n ast.Node) bool {
		if fd, ok := n.(*ast.FuncDecl); ok {
			if fd.Recv == nil && fd.Name.Name == "getAllChangedFilesBetweenTrees" {
				fn = fd
				return false
			}
		}
		return true
	})

	if fn == nil {
		fmt.Println("FAIL: getAllChangedFilesBetweenTrees function not found")
		os.Exit(2)
	}

	// Anti-stub: body must have > 5 statements
	stmtCount := 0
	if fn.Body != nil {
		stmtCount = len(fn.Body.List)
	}
	if stmtCount < 5 {
		fmt.Println("FAIL: getAllChangedFilesBetweenTrees body too short (stub detected)")
		os.Exit(3)
	}

	usesGetFileContent := false
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		ident, ok := call.Fun.(*ast.Ident)
		if !ok {
			return true
		}
		if ident.Name == "getFileContent" {
			usesGetFileContent = true
		}
		return true
	})

	if !usesGetFileContent {
		fmt.Println("PASS: getAllChangedFilesBetweenTrees no longer calls getFileContent")
	} else {
		fmt.Println("FAIL: getAllChangedFilesBetweenTrees still calls getFileContent (not optimized)")
		os.Exit(4)
	}
}

// checkCheckpointGuardRemoved verifies that the caller of
// calculatePromptAttributionAtStart no longer has the CheckpointCount > 0
// guard — allowing attribution for the first checkpoint.
func checkCheckpointGuardRemoved(f *ast.File) {
	// Find the function body that contains the call to calculatePromptAttributionAtStart
	var fn *ast.FuncDecl
	ast.Inspect(f, func(n ast.Node) bool {
		if fd, ok := n.(*ast.FuncDecl); ok {
			if fd.Recv != nil && fd.Name.Name == "InitializeSession" {
				fn = fd
				return false
			}
		}
		return true
	})

	if fn == nil {
		fmt.Println("FAIL: InitializeSession function not found")
		os.Exit(2)
	}

	// Check if calculatePromptAttributionAtStart is called inside a
	// conditional on CheckpointCount > 0
	calledInGuard := false
	calledUnconditionally := false

	ast.Inspect(fn.Body, func(n ast.Node) bool {
		ifStmt, ok := n.(*ast.IfStmt)
		if !ok {
			return true
		}
		// Check if this if-stmt guards on CheckpointCount
		binary, ok := ifStmt.Cond.(*ast.BinaryExpr)
		if !ok {
			return true
		}
		sel, ok := binary.X.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if sel.Sel.Name != "CheckpointCount" {
			return true
		}

		// Check if the body contains calculatePromptAttributionAtStart
		ast.Inspect(ifStmt.Body, func(n2 ast.Node) bool {
			call, ok := n2.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel2, ok := call.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			if sel2.Sel.Name == "calculatePromptAttributionAtStart" {
				calledInGuard = true
			}
			return true
		})
		return true
	})

	// Also check for unconditional call
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if sel.Sel.Name == "calculatePromptAttributionAtStart" {
			calledUnconditionally = true
		}
		return true
	})

	if calledInGuard {
		fmt.Println("FAIL: calculatePromptAttributionAtStart still guarded by CheckpointCount check")
		os.Exit(3)
	} else if calledUnconditionally {
		fmt.Println("PASS: calculatePromptAttributionAtStart called unconditionally")
	} else {
		fmt.Println("FAIL: calculatePromptAttributionAtStart call not found in PrePromptHook")
		os.Exit(4)
	}
}
GOEOF

# Pre-build the AST checker once so we can invoke it as a binary
# (go run on a .go file plus extra .go args confuses go's source-file parser
# with "named files must all be in one directory; have /tmp and .")
cd /tmp/ast_check_runner_pkg && go mod init astcheck 2>/dev/null && go build -o /tmp/ast_check_runner_bin main.go 2>/dev/null
cd "$STRATEGY_DIR"

# ------------------------------------------------------------------
# GATE: F2P_BUILDS — code compiles without errors
# ------------------------------------------------------------------
echo "=== GATE: F2P_BUILDS ==="
cd "$STRATEGY_DIR"
if go build ./... 2>&1; then
    echo "PASS: code builds"
    emit_gate "F2P_BUILDS" true
else
    echo "FAIL: code does not build"
    emit_gate "F2P_BUILDS" false
fi

# ------------------------------------------------------------------
# GATE: F2P_TESTS_PASS — existing and new tests pass
# ------------------------------------------------------------------
echo "=== GATE: F2P_TESTS_PASS ==="
if go test ./... 2>&1; then
    echo "PASS: all tests pass"
    emit_gate "F2P_TESTS_PASS" true
else
    echo "FAIL: some tests failed"
    emit_gate "F2P_TESTS_PASS" false
fi

# ------------------------------------------------------------------
# GATE: F2P_DEBUG_LOGS_EXIST — calculatePromptAttributionAtStart has
# logging.Debug calls in its error-return paths.
# Weights: 0.22 (core ask from instruction.md)
# ------------------------------------------------------------------
echo "=== GATE: F2P_DEBUG_LOGS_EXIST ==="
RESULT=$(cd "$STRATEGY_DIR" && /tmp/ast_check_runner_bin manual_commit_hooks.go debug_logs 2>&1)
RC=$?
echo "$RESULT"
if [ $RC -eq 0 ]; then
    emit_gate "F2P_DEBUG_LOGS_EXIST" true
else
    emit_gate "F2P_DEBUG_LOGS_EXIST" false
fi

# ------------------------------------------------------------------
# GATE: F2P_HASH_BASED_DIFF — getAllChangedFilesBetweenTrees uses
# hash-based comparison, not content-based (getFileContent)
# Weights: 0.10 (performance improvement discovery)
# ------------------------------------------------------------------
echo "=== GATE: F2P_HASH_BASED_DIFF ==="
RESULT=$(cd "$STRATEGY_DIR" && /tmp/ast_check_runner_bin manual_commit_attribution.go no_getfilecontent_in_diff 2>&1)
RC=$?
echo "$RESULT"
if [ $RC -eq 0 ]; then
    emit_gate "F2P_HASH_BASED_DIFF" true
else
    emit_gate "F2P_HASH_BASED_DIFF" false
fi

# ------------------------------------------------------------------
# GATE: F2P_CP_GUARD_REMOVED — CheckpointCount > 0 guard removed
# so first-checkpoint attribution works
# Weights: 0.08 (deep bug fix discovery)
# ------------------------------------------------------------------
echo "=== GATE: F2P_CP_GUARD_REMOVED ==="
RESULT=$(cd "$STRATEGY_DIR" && /tmp/ast_check_runner_bin manual_commit_hooks.go checkpoint_guard_removed 2>&1)
RC=$?
echo "$RESULT"
if [ $RC -eq 0 ]; then
    emit_gate "F2P_CP_GUARD_REMOVED" true
else
    emit_gate "F2P_CP_GUARD_REMOVED" false
fi

# ------------------------------------------------------------------
# GATE: F2P_NEW_TESTS_EXIST — new test functions added for the
# optimized/changed functions (anti-regression)
# Weights: 0.08 (test coverage)
# ------------------------------------------------------------------
echo "=== GATE: F2P_NEW_TESTS_EXIST ==="
NEW_TEST_COUNT=0
# Check for test functions that WOULD be added during this session
for test_func in "TestGetAllChangedFilesBetweenTrees" "TestPromptAttribution_CapturesPrePromptEdits" "TestGetFileContent"; do
    if grep -q "func $test_func" "$STRATEGY_DIR/manual_commit_attribution_test.go" "$STRATEGY_DIR/manual_commit_staging_test.go" 2>/dev/null; then
        NEW_TEST_COUNT=$((NEW_TEST_COUNT + 1))
    fi
done
# Also count total test functions to detect any new ones
TOTAL_TESTS=$(grep -c "^func Test" "$STRATEGY_DIR/manual_commit_attribution_test.go" "$STRATEGY_DIR/manual_commit_staging_test.go" 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
# Base commit has 3 + 17 = 20 tests
if [ "$TOTAL_TESTS" -gt 20 ] || [ "$NEW_TEST_COUNT" -ge 1 ]; then
    echo "PASS: new test functions detected ($NEW_TEST_COUNT specific, $TOTAL_TESTS total)"
    emit_gate "F2P_NEW_TESTS_EXIST" true
else
    echo "FAIL: no new test functions found ($TOTAL_TESTS total, same as base)"
    emit_gate "F2P_NEW_TESTS_EXIST" false
fi

# ------------------------------------------------------------------
# P2P Regression gates (zero weight — record failures as diagnostics/penalty inputs)
# ------------------------------------------------------------------
echo "=== GATE: P2P_GETFILECONTENT_EXISTS ==="
if grep -q "func getFileContent" "$STRATEGY_DIR/manual_commit_attribution.go"; then
    echo "PASS: getFileContent function still exists (not accidentally deleted)"
    emit_gate "P2P_GETFILECONTENT_EXISTS" true
else
    echo "FAIL: getFileContent function is missing — it's still used elsewhere"
    emit_gate "P2P_GETFILECONTENT_EXISTS" false
fi

echo "=== GATE: P2P_GETALLCHANGED_EXISTS ==="
if grep -q "func getAllChangedFilesBetweenTrees" "$STRATEGY_DIR/manual_commit_attribution.go"; then
    echo "PASS: getAllChangedFilesBetweenTrees function still exists"
    emit_gate "P2P_GETALLCHANGED_EXISTS" true
else
    echo "FAIL: getAllChangedFilesBetweenTrees function was deleted"
    emit_gate "P2P_GETALLCHANGED_EXISTS" false
fi

# ------------------------------------------------------------------
# Write all verdicts to gates.json
# ------------------------------------------------------------------
echo "$verdicts_json" > "$GATES_FILE"
echo "Verdicts: $verdicts_json"

# ------------------------------------------------------------------
# Compute weighted-replace reward
# ------------------------------------------------------------------
python3 << 'PYEOF'
import json, traceback

try:
    with open("/logs/verifier/gates.json") as f:
        verdicts = json.load(f)
except Exception:
    traceback.print_exc()
    verdicts = {}

# F2P weights (must sum ≤ 1.0, each ≤ 0.30 per R006)
WEIGHTS = {
    "F2P_BUILDS":          0.12,
    "F2P_TESTS_PASS":      0.18,
    "F2P_DEBUG_LOGS_EXIST":0.20,
    "F2P_HASH_BASED_DIFF": 0.10,
    "F2P_CP_GUARD_REMOVED":0.08,
    "F2P_NEW_TESTS_EXIST": 0.07,
}
# Sum = 0.75, inner_weight = 0.25

# P2P regression gates — record failures as diagnostics/penalty inputs
P2P_GATES = ["P2P_GETFILECONTENT_EXISTS", "P2P_GETALLCHANGED_EXISTS"]

# Check P2P gates first
p2p_failed = False  # P2P_REGRESSION informational only (v043 fix)
if p2p_failed:
    reward = 0.0
    print("P2P regression gate(s) FAILED => reward = 0.0")
else:
    f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS)
    if not f2p_any_pass:
        reward = 0.0
        print("No F2P gates passed => reward = 0.0")
    else:
        inner_weight = max(0.0, 1.0 - sum(WEIGHTS.values()))
        reward = inner_weight
        for gid, w in WEIGHTS.items():
            if verdicts.get(gid):
                reward += float(w)
        if reward > 1.0:
            reward = 1.0

print(f"Final reward: {reward:.4f}")
with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{reward:.6f}\n")
PYEOF

# Defensive fallback: if for any reason the Python block did not write a
# numeric reward (e.g. import error, traceback before the write), guarantee
# a valid file so the orchestrator never sees MISSING / non-numeric content.
if ! [ -s /logs/verifier/reward.txt ] || ! grep -Eq '^[0-9]+\.?[0-9]*$' /logs/verifier/reward.txt; then
    echo "WARN: reward.txt missing or non-numeric — writing 0.0 fallback" >&2
    echo "0.000000" > /logs/verifier/reward.txt
fi

echo "Done. Reward written to /logs/verifier/reward.txt"
