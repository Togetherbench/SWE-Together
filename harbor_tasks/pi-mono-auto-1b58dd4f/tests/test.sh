#!/bin/bash
set +e

# =============================================================================
# Verifier for pi-mono extension-binding bug fix
#
# Bug: When pi starts with zero user extensions, modes gate bindExtensions()
# behind an extensionRunner check. This means UI context is never stored,
# so after /reload, new extensions can't use ui.notify() etc.
#
# Fix: Call session.bindExtensions() unconditionally in all 3 modes:
#   - interactive-mode.ts: initExtensions() must not early-return before bindExtensions
#   - print-mode.ts: bindExtensions must not be gated by if(extensionRunner)
#   - rpc-mode.ts: same as print-mode
# =============================================================================

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

SCORE=0.0

INTERACTIVE_MODE="packages/coding-agent/src/modes/interactive/interactive-mode.ts"
PRINT_MODE="packages/coding-agent/src/modes/print-mode.ts"
RPC_MODE="packages/coding-agent/src/modes/rpc/rpc-mode.ts"
AGENT_SESSION="packages/coding-agent/src/core/agent-session.ts"

cd /workspace/pi-mono

# =============================================================================
# Pre-check: TypeScript compilation (used by F2P gates below)
# This is the TypeScript compilation gate required for TS tasks (>=0.2 weight).
# It is incorporated into each F2P gate: if compilation fails, all F2P gates
# fail automatically.
# =============================================================================
echo "=== Pre-check: TypeScript compilation ==="
npx tsgo --noEmit 2>&1
TSC_PASS=$?
if [ $TSC_PASS -eq 0 ]; then
    echo "TypeScript compilation: PASS"
else
    echo "TypeScript compilation: FAIL (exit $TSC_PASS)"
    echo "All F2P gates will fail due to compilation error."
fi

# =============================================================================
# Helper: AST-based check for unconditional bindExtensions call
# Uses TypeScript compiler API (node -e) to parse the source file and verify
# that session.bindExtensions() is called on a code path reachable when
# extensionRunner is null/undefined.
# =============================================================================

check_unconditional_bind() {
    local FILE_PATH="$1"
    local FILE_LABEL="$2"

    node -e "
const ts = require('typescript');
const fs = require('fs');

const filePath = '$FILE_PATH';
if (!fs.existsSync(filePath)) {
    console.log('FAIL: file not found: $FILE_LABEL');
    process.exit(1);
}
const src = fs.readFileSync(filePath, 'utf8');
const sf = ts.createSourceFile(filePath, src, ts.ScriptTarget.Latest, true);

let bindCalls = [];
let guardedBindCalls = 0;

function isInsideRunnerGuard(node) {
    let parent = node.parent;
    while (parent) {
        if (ts.isIfStatement(parent)) {
            const condText = parent.expression.getText(sf);
            if (condText.includes('extensionRunner')) {
                return true;
            }
        }
        // Check for early-return guard: if(!extensionRunner){...return...} before this node
        if (ts.isBlock(parent) || ts.isSourceFile(parent)) {
            const stmts = parent.statements ? Array.from(parent.statements) : [];
            for (const stmt of stmts) {
                if (stmt.pos >= node.pos) break;
                if (ts.isIfStatement(stmt)) {
                    const cond = stmt.expression.getText(sf);
                    if (cond.includes('!extensionRunner') || cond.includes('!this.session.extensionRunner')) {
                        const thenText = stmt.thenStatement.getText(sf);
                        if (thenText.includes('return')) {
                            return true;
                        }
                    }
                }
            }
        }
        parent = parent.parent;
    }
    return false;
}

function visit(node) {
    if (ts.isCallExpression(node)) {
        const callText = node.expression.getText(sf);
        if (callText.includes('bindExtensions')) {
            bindCalls.push({ text: callText, pos: node.pos });
            if (isInsideRunnerGuard(node)) {
                guardedBindCalls++;
            }
        }
    }
    ts.forEachChild(node, visit);
}
visit(sf);

if (bindCalls.length === 0) {
    console.log('FAIL: no bindExtensions calls found in $FILE_LABEL');
    process.exit(1);
}

const ungardedCalls = bindCalls.length - guardedBindCalls;
if (ungardedCalls > 0) {
    console.log('PASS: ' + ungardedCalls + ' unguarded bindExtensions call(s) in $FILE_LABEL');
    process.exit(0);
} else {
    console.log('FAIL: all bindExtensions calls in $FILE_LABEL gated behind extensionRunner check');
    process.exit(1);
}
" 2>&1
    return $?
}

# =============================================================================
# Gate 1 (F2P): interactive-mode.ts — extension bindings work after reload
# Weight 0.30
#
# Requires: TypeScript compilation passes AND the extension binding flow is
# fixed so that bindExtensions gets called even when starting with no extensions.
#
# Accepts multiple valid fix approaches:
#   A) bindExtensions called unconditionally in initExtensions (gold fix)
#   B) handleReloadCommand calls initExtensions/bindExtensions when extensions
#      first appear during reload (alternative valid approach)
#   C) Any other change that ensures bindExtensions is reachable when starting
#      with no extensions
#
# F2P: base has guarded call → FAIL. Correct fix → PASS.
# =============================================================================
echo ""
echo "=== Gate 1: TypeScript compilation + interactive-mode.ts fix (F2P, weight 0.30) ==="
GATE1_EXIT=1
if [ $TSC_PASS -eq 0 ]; then
    # Try approach A: unconditional bindExtensions in initExtensions
    check_unconditional_bind "$INTERACTIVE_MODE" "interactive-mode.ts"
    GATE1_EXIT=$?

    if [ $GATE1_EXIT -ne 0 ]; then
        # Try approach B: handleReloadCommand calls initExtensions or bindExtensions
        # when extensions appear for the first time during reload
        echo "Checking alternative fix: handleReloadCommand re-initialization..."
        node -e "
const ts = require('typescript');
const fs = require('fs');

const filePath = '$INTERACTIVE_MODE';
const src = fs.readFileSync(filePath, 'utf8');
const sf = ts.createSourceFile(filePath, src, ts.ScriptTarget.Latest, true);

let handleReloadFound = false;
let callsInitOrBind = false;

function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name) {
        const name = node.name.getText(sf);
        if (name === 'handleReloadCommand') {
            handleReloadFound = true;
            const bodyText = node.body ? node.body.getText(sf) : '';
            // Check if handleReloadCommand now calls initExtensions() or bindExtensions()
            // in a context that handles the first-extension-load case
            if ((bodyText.includes('initExtensions') || bodyText.includes('bindExtensions'))
                && (bodyText.includes('hadRunner') || bodyText.includes('beforeReload')
                    || bodyText.includes('hadExtensions') || bodyText.includes('hadRunnerBefore'))) {
                callsInitOrBind = true;
            }
        }
    }
    ts.forEachChild(node, visit);
}
visit(sf);

if (!handleReloadFound) {
    console.log('FAIL: handleReloadCommand not found');
    process.exit(1);
}
if (callsInitOrBind) {
    console.log('PASS: handleReloadCommand handles first-time extension load');
    process.exit(0);
} else {
    console.log('FAIL: no valid extension-binding fix detected in interactive-mode.ts');
    process.exit(1);
}
" 2>&1
        GATE1_EXIT=$?
    fi
else
    echo "FAIL: TypeScript compilation failed"
fi
if [ $GATE1_EXIT -eq 0 ]; then
    SCORE=$(node -e "console.log($SCORE + 0.30)")
fi

# =============================================================================
# Gate 2 (F2P): print-mode.ts — bindExtensions called unconditionally
# Weight 0.30
#
# Requires: TypeScript compilation passes AND bindExtensions not inside
# if(extensionRunner) block.
# F2P: base has guarded call → FAIL. Correct fix removes guard → PASS.
# =============================================================================
echo ""
echo "=== Gate 2: TypeScript compilation + print-mode.ts fix (F2P, weight 0.30) ==="
if [ $TSC_PASS -eq 0 ]; then
    check_unconditional_bind "$PRINT_MODE" "print-mode.ts"
    GATE2_EXIT=$?
else
    echo "FAIL: TypeScript compilation failed"
    GATE2_EXIT=1
fi
if [ $GATE2_EXIT -eq 0 ]; then
    SCORE=$(node -e "console.log($SCORE + 0.30)")
fi

# =============================================================================
# Gate 3 (F2P): rpc-mode.ts — bindExtensions called unconditionally
# Weight 0.30
#
# Requires: TypeScript compilation passes AND bindExtensions not inside
# if(extensionRunner) block.
# F2P: base has guarded call → FAIL. Correct fix removes guard → PASS.
# =============================================================================
echo ""
echo "=== Gate 3: TypeScript compilation + rpc-mode.ts fix (F2P, weight 0.30) ==="
if [ $TSC_PASS -eq 0 ]; then
    check_unconditional_bind "$RPC_MODE" "rpc-mode.ts"
    GATE3_EXIT=$?
else
    echo "FAIL: TypeScript compilation failed"
    GATE3_EXIT=1
fi
if [ $GATE3_EXIT -eq 0 ]; then
    SCORE=$(node -e "console.log($SCORE + 0.30)")
fi

# =============================================================================
# Gate 4 (P2P): agent-session.ts _buildRuntime calls _applyExtensionBindings
# Weight 0.10
#
# Regression guard: ensures the core reload mechanism still works. The base
# code already has this, and the correct fix must preserve it.
# P2P: passes on unmodified base AND on correct fix.
# =============================================================================
echo ""
echo "=== Gate 4: agent-session.ts _applyExtensionBindings in _buildRuntime (P2P, weight 0.10) ==="
GATE4=$(node -e "
const ts = require('typescript');
const fs = require('fs');

const filePath = '$AGENT_SESSION';
if (!fs.existsSync(filePath)) {
    console.log('FAIL: file not found');
    process.exit(1);
}
const src = fs.readFileSync(filePath, 'utf8');
const sf = ts.createSourceFile(filePath, src, ts.ScriptTarget.Latest, true);

let buildRuntimeFound = false;
let applyBindingsInBuildRuntime = false;

function visit(node) {
    if (ts.isMethodDeclaration(node) && node.name) {
        const name = node.name.getText(sf);
        if (name === '_buildRuntime') {
            buildRuntimeFound = true;
            function innerVisit(inner) {
                if (ts.isCallExpression(inner)) {
                    const callText = inner.expression.getText(sf);
                    if (callText.includes('_applyExtensionBindings') || callText.includes('applyExtensionBindings')) {
                        applyBindingsInBuildRuntime = true;
                    }
                }
                ts.forEachChild(inner, innerVisit);
            }
            ts.forEachChild(node, innerVisit);
        }
    }
    ts.forEachChild(node, visit);
}
visit(sf);

if (!buildRuntimeFound) {
    console.log('FAIL: _buildRuntime method not found in agent-session.ts');
    process.exit(1);
}
if (!applyBindingsInBuildRuntime) {
    console.log('FAIL: _buildRuntime does not call _applyExtensionBindings');
    process.exit(1);
}
console.log('PASS: _buildRuntime correctly calls _applyExtensionBindings');
process.exit(0);
" 2>&1)
GATE4_EXIT=$?
echo "$GATE4"
if [ $GATE4_EXIT -eq 0 ]; then
    SCORE=$(node -e "console.log($SCORE + 0.10)")
fi

# =============================================================================
# Compute final reward
# =============================================================================
echo ""
echo "=== Final Score ==="
REWARD=$(node -e "
const score = $SCORE;
const reward = Math.round(score * 100) / 100;
console.log(reward);
")
echo "Score: $SCORE = $REWARD"
echo "$REWARD" > "$REWARD_FILE"
echo "Reward written to $REWARD_FILE"
