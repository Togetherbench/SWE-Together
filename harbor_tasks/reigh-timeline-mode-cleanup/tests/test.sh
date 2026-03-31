#!/usr/bin/env bash
#
# Verification tests for the reigh TimelineModeContent refactor.
#
# Scoring: 20 total points
#   Behavioral (F2P/P2P):      16 pts (80%) — tests 8, 9a, 9b, 9c
#   Structural (TS AST/Bronze): 4 pts (20%) — tests 1-7 (all gated behind TSC)
#
# TSC gate: ALL structural tests only count if tsc passes.
# Without TSC passing, the agent gets 0 from structural tests.
# This prevents gaming via stub files that parse but break compilation.
#
# Gaming analysis:
#   Base state (no changes):    P2P only → 2/20 = 0.10
#   Delete TMC only (no tsc):   P2P only → 2/20 = 0.10
#   Delete TMC + tsc passes:    1+1+0+0+2 = 4/20 = 0.20 (unlikely tsc passes without fixing ShotImagesEditor)
#   Stub with tsc pass:         Requires real refactoring for tsc to pass → genuine solution
#   Core refactor no cleanup:   4+2+8+0 = 14/20 = 0.70
#   Full solution:              20/20 = 1.0
#
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p "$(dirname "$REWARD_FILE")"

PASS=0
TOTAL=20

REPO="/workspace/reigh"
SRC="$REPO/src"
TMC="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$REPO/src/tools/travel-between-images/components/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$REPO/src/tools/travel-between-images/components/ShotImagesEditor.tsx"
TIMELINE="$REPO/src/tools/travel-between-images/components/Timeline.tsx"
TC="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/TimelineContainer.tsx"
TC_TYPES="$REPO/src/tools/travel-between-images/components/Timeline/TimelineContainer/types.ts"
TS_MOD="$REPO/node_modules/typescript"

TSC_PASSED=0
CORE_PASS=0    # count of core structural tests (1-4) that pass
CLEANUP_PASS=0 # count of cleanup structural tests (5-7) that pass

###############################################################################
# BEHAVIORAL — TypeScript compilation (must run FIRST as gate for structural)
###############################################################################

echo "=== TypeScript compilation (tsc --noEmit) ==="
if command -v npx &>/dev/null && [ -d "$REPO/node_modules" ] && [ -f "$REPO/tsconfig.json" ]; then
    cd "$REPO"
    TSC_OUT=$(npx tsc --noEmit 2>&1)
    TSC_EXIT=$?
    if [ "$TSC_EXIT" -eq 0 ]; then
        echo "tsc: PASS (zero errors)"
        TSC_PASSED=1
    else
        ERROR_COUNT=$(echo "$TSC_OUT" | grep -c "error TS" || echo "?")
        echo "FAIL: TypeScript compilation failed ($ERROR_COUNT errors)"
        echo "$TSC_OUT" | head -20
    fi
else
    echo "SKIP: node_modules not available"
fi

###############################################################################
# STRUCTURAL — Core Refactoring (4 pts: 1+1+1+1) — ALL GATED BEHIND TSC
###############################################################################

# Test 1 (1 pt, Bronze): TimelineModeContent.tsx is deleted
echo ""
echo "=== Test 1/9: TimelineModeContent.tsx deleted ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate (structural tests require tsc pass)"
elif [ ! -f "$TMC" ]; then
    echo "PASS"
    PASS=$((PASS + 1))
    CORE_PASS=$((CORE_PASS + 1))
else
    echo "FAIL: TimelineModeContent.tsx still exists"
fi

# Test 2 (1 pt, Bronze): Barrel file no longer exports TimelineModeContent
echo ""
echo "=== Test 2/9: Barrel file cleaned ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate"
elif [ ! -f "$BARREL" ]; then
    echo "PASS: Barrel file deleted (acceptable)"
    PASS=$((PASS + 1))
    CORE_PASS=$((CORE_PASS + 1))
elif node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$BARREL', 'utf8');
const sf = ts.createSourceFile('index.ts', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
let found = false;
function visit(node) {
    if (ts.isExportDeclaration(node) && node.moduleSpecifier &&
        ts.isStringLiteral(node.moduleSpecifier) &&
        node.moduleSpecifier.text.includes('TimelineModeContent')) {
        found = true;
    }
    if (ts.isExportSpecifier(node) && node.name &&
        (node.name.escapedText === 'TimelineModeContent' ||
         node.name.escapedText === 'TimelineModeContentProps')) {
        found = true;
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
if (found) { console.error('FAIL: Barrel still exports TimelineModeContent'); process.exit(1); }
console.log('PASS: Barrel no longer exports TimelineModeContent');
" 2>/dev/null; then
    PASS=$((PASS + 1))
    CORE_PASS=$((CORE_PASS + 1))
else
    echo "FAIL: Barrel still exports TimelineModeContent"
fi

# Test 3 (1 pt, Silver/AST): ShotImagesEditor renders <Timeline> with substantial props
echo ""
echo "=== Test 3/9: ShotImagesEditor renders <Timeline> with props ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate"
elif [ -f "$SHOT_EDITOR" ]; then
    node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const sf = ts.createSourceFile('ShotImagesEditor.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

// Must NOT have <TimelineModeContent> in JSX
let hasTMC = false;
function findTMC(node) {
    if ((ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
        ts.isIdentifier(node.tagName) && node.tagName.escapedText === 'TimelineModeContent') {
        hasTMC = true;
    }
    ts.forEachChild(node, findTMC);
}
ts.forEachChild(sf, findTMC);
if (hasTMC) {
    console.error('FAIL: <TimelineModeContent> JSX still present');
    process.exit(1);
}

// Must have <Timeline> with >=15 named attributes OR at least one spread attribute
let found = false;
function findTimeline(node) {
    if ((ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) &&
        ts.isIdentifier(node.tagName) && node.tagName.escapedText === 'Timeline') {
        let named = 0, hasSpread = false;
        for (const prop of node.attributes.properties) {
            if (ts.isJsxSpreadAttribute(prop)) hasSpread = true;
            else named++;
        }
        if (hasSpread || named >= 15) found = true;
    }
    ts.forEachChild(node, findTimeline);
}
ts.forEachChild(sf, findTimeline);
if (!found) {
    console.error('FAIL: <Timeline> not found with sufficient props (need >=15 named or a spread)');
    process.exit(1);
}
console.log('PASS: <Timeline> rendered with sufficient props');
" 2>/dev/null && {
        PASS=$((PASS + 1))
        CORE_PASS=$((CORE_PASS + 1))
    } || echo "FAIL: ShotImagesEditor does not render <Timeline> properly"
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

# Test 4 (1 pt, Silver/AST): Unpositioned generations div inlined into ShotImagesEditor
echo ""
echo "=== Test 4/9: Unpositioned generations div inlined ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate"
elif [ -f "$SHOT_EDITOR" ]; then
    node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const sf = ts.createSourceFile('ShotImagesEditor.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

// Check 1: 'unpositioned generation' text must appear somewhere
let hasText = false;
function findText(node) {
    if (hasText) return;
    if ((ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) &&
        node.text.includes('unpositioned generation')) { hasText = true; }
    if (ts.isJsxText(node) && node.text.includes('unpositioned generation')) { hasText = true; }
    if (ts.isTemplateHead(node) && node.text.includes('unpositioned generation')) { hasText = true; }
    if (ts.isTemplateMiddle(node) && node.text.includes('unpositioned generation')) { hasText = true; }
    if (ts.isTemplateTail(node) && node.text.includes('unpositioned generation')) { hasText = true; }
    ts.forEachChild(node, findText);
}
ts.forEachChild(sf, findText);

if (!hasText) {
    console.error('FAIL: \"unpositioned generation\" text not found in ShotImagesEditor');
    process.exit(1);
}

// Check 2: unpositionedGenerationsCount identifier is used (conditional rendering)
let hasCountId = false;
function findCount(node) {
    if (hasCountId) return;
    if (ts.isIdentifier(node) && node.escapedText === 'unpositionedGenerationsCount') {
        hasCountId = true;
    }
    ts.forEachChild(node, findCount);
}
ts.forEachChild(sf, findCount);

if (!hasCountId) {
    console.error('FAIL: unpositionedGenerationsCount not used in ShotImagesEditor');
    process.exit(1);
}
console.log('PASS');
" 2>/dev/null && {
        PASS=$((PASS + 1))
        CORE_PASS=$((CORE_PASS + 1))
    } || echo "FAIL: Unpositioned generations div not properly inlined"
else
    echo "FAIL: ShotImagesEditor.tsx not found"
fi

###############################################################################
# STRUCTURAL — Dead Prop Cleanup + Import Graph (0 pts standalone, part of 9b)
# These only count via test 9b (TSC + cleanup). Tracked via CLEANUP_PASS.
###############################################################################

# Test 5: hookData prop removed from Timeline.tsx interface
echo ""
echo "=== Test 5/9: hookData removed from Timeline.tsx ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate"
elif [ -f "$TIMELINE" ]; then
    node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let foundHookData = false;
function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
        for (const member of node.members) {
            if (ts.isPropertySignature(member) && member.name &&
                ts.isIdentifier(member.name) &&
                (member.name.escapedText === 'hookData' || member.name.escapedText === 'propHookData')) {
                foundHookData = true;
            }
        }
    }
    ts.forEachChild(node, visit);
}
ts.forEachChild(sf, visit);
if (foundHookData) { console.error('FAIL: hookData/propHookData still in Timeline interface'); process.exit(1); }
console.log('PASS');
" 2>/dev/null && {
        CLEANUP_PASS=$((CLEANUP_PASS + 1))
    } || echo "FAIL: hookData still present in Timeline.tsx"
else
    echo "FAIL: Timeline.tsx not found"
fi

# Test 6: enhancedPrompts / EMPTY_ENHANCED_PROMPTS removed from Timeline.tsx
echo ""
echo "=== Test 6/9: enhancedPrompts removed from Timeline.tsx ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate"
elif [ -f "$TIMELINE" ]; then
    node -e "
const ts = require('$TS_MOD');
const fs = require('fs');
const src = fs.readFileSync('$TIMELINE', 'utf8');
const sf = ts.createSourceFile('Timeline.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

let hasConst = false;
function findConst(node) {
    if (hasConst) return;
    if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name) &&
        node.name.escapedText === 'EMPTY_ENHANCED_PROMPTS') { hasConst = true; }
    ts.forEachChild(node, findConst);
}
ts.forEachChild(sf, findConst);
if (hasConst) { console.error('FAIL: EMPTY_ENHANCED_PROMPTS still present'); process.exit(1); }

let hasInInterface = false;
function findInterface(node) {
    if (hasInInterface) return;
    if (ts.isInterfaceDeclaration(node)) {
        for (const member of node.members) {
            if (ts.isPropertySignature(member) && member.name &&
                ts.isIdentifier(member.name) && member.name.escapedText === 'enhancedPrompts') {
                hasInInterface = true;
            }
        }
    }
    ts.forEachChild(node, findInterface);
}
ts.forEachChild(sf, findInterface);
if (hasInInterface) { console.error('FAIL: enhancedPrompts still in Timeline interface'); process.exit(1); }
console.log('PASS');
" 2>/dev/null && {
        CLEANUP_PASS=$((CLEANUP_PASS + 1))
    } || echo "FAIL: enhancedPrompts still in Timeline.tsx"
else
    echo "FAIL: Timeline.tsx not found"
fi

# Test 7: Import graph clean + TimelineContainer cleanup
echo ""
echo "=== Test 7/9: Import graph clean + TimelineContainer cleanup ==="
if [ "$TSC_PASSED" -eq 0 ]; then
    echo "SKIP: TSC gate"
elif node -e "
const ts = require('$TS_MOD');
const { execSync } = require('child_process');
const fs = require('fs');

// 1. No .ts/.tsx file should import or re-export TimelineModeContent
const files = execSync('find $SRC -name \"*.ts\" -o -name \"*.tsx\"', { encoding: 'utf8' })
    .trim().split('\n').filter(Boolean);

for (const file of files) {
    try {
        const src = fs.readFileSync(file, 'utf8');
        const ext = file.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS;
        const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ext);
        function visit(node) {
            if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
                node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier) &&
                node.moduleSpecifier.text.includes('TimelineModeContent')) {
                console.error('FAIL: ' + file + ' still references TimelineModeContent');
                process.exit(1);
            }
            ts.forEachChild(node, visit);
        }
        ts.forEachChild(sf, visit);
    } catch(e) { /* skip unparseable files */ }
}

// 2. ShotImagesEditor must import Timeline (named or default)
const editorSrc = fs.readFileSync('$SHOT_EDITOR', 'utf8');
const editorSf = ts.createSourceFile('ShotImagesEditor.tsx', editorSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
let importsTimeline = false;
function findImport(node) {
    if (ts.isImportDeclaration(node) && node.moduleSpecifier &&
        ts.isStringLiteral(node.moduleSpecifier) &&
        node.moduleSpecifier.text.includes('Timeline')) {
        if (node.importClause) {
            if (node.importClause.name &&
                node.importClause.name.escapedText === 'Timeline') { importsTimeline = true; }
            if (node.importClause.namedBindings && ts.isNamedImports(node.importClause.namedBindings)) {
                for (const el of node.importClause.namedBindings.elements) {
                    if (el.name.escapedText === 'Timeline') importsTimeline = true;
                }
            }
        }
    }
    ts.forEachChild(node, findImport);
}
ts.forEachChild(editorSf, findImport);
if (!importsTimeline) {
    console.error('FAIL: ShotImagesEditor does not import Timeline');
    process.exit(1);
}

// 3. enhancedPrompts removed from TimelineContainer types
if (fs.existsSync('$TC_TYPES')) {
    const tcSrc = fs.readFileSync('$TC_TYPES', 'utf8');
    const tcSf = ts.createSourceFile('types.ts', tcSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    function visitTypes(node) {
        if (ts.isInterfaceDeclaration(node) || ts.isTypeLiteralNode(node)) {
            for (const m of (node.members || [])) {
                if (ts.isPropertySignature(m) && m.name && ts.isIdentifier(m.name) &&
                    m.name.escapedText === 'enhancedPrompts') {
                    console.error('FAIL: enhancedPrompts still in TimelineContainer types');
                    process.exit(1);
                }
            }
        }
        ts.forEachChild(node, visitTypes);
    }
    ts.forEachChild(tcSf, visitTypes);
}

// 4. enhancedPromptFromProps removed from TimelineContainer.tsx
if (fs.existsSync('$TC')) {
    const tcCompSrc = fs.readFileSync('$TC', 'utf8');
    const tcCompSf = ts.createSourceFile('TimelineContainer.tsx', tcCompSrc, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
    function visitTC(node) {
        if (ts.isIdentifier(node) && node.escapedText === 'enhancedPromptFromProps') {
            console.error('FAIL: enhancedPromptFromProps still in TimelineContainer.tsx');
            process.exit(1);
        }
        ts.forEachChild(node, visitTC);
    }
    ts.forEachChild(tcCompSf, visitTC);
}

console.log('PASS: Import graph clean, TimelineContainer cleaned');
" 2>/dev/null; then
    CLEANUP_PASS=$((CLEANUP_PASS + 1))
else
    echo "FAIL: Import graph or TimelineContainer cleanup incomplete"
fi

###############################################################################
# BEHAVIORAL — Pass-to-Pass: upstream vitest tests (2 pts, 10%)
###############################################################################

echo ""
echo "=== Test 8/9: P2P upstream vitest tests ==="
P2P_AWARDED=0
cd "$REPO"
if [ -f "$REPO/node_modules/.bin/vitest" ]; then
    # Run CPU-safe unit tests unrelated to Timeline components
    VITEST_OUT=$(timeout 60 npx vitest run src/test/supabaseAuth.test.ts src/test/systemLogger.test.ts --reporter=verbose 2>&1)
    VITEST_EXIT=$?
    if [ $VITEST_EXIT -eq 0 ]; then
        echo "PASS: upstream vitest tests pass"
        PASS=$((PASS + 2))
        P2P_AWARDED=1
    elif echo "$VITEST_OUT" | grep -qiE "Cannot find module|ERR_MODULE_NOT_FOUND|Error: Failed to collect|Config error|no test file|ENOENT|Cannot read config"; then
        echo "SKIP: vitest infrastructure issue (not agent's fault), awarding P2P"
        PASS=$((PASS + 2))
        P2P_AWARDED=1
    else
        echo "FAIL: upstream vitest tests failed (agent may have broken existing code)"
        echo "$VITEST_OUT" | tail -10
    fi
else
    echo "SKIP: vitest not installed, awarding P2P"
    PASS=$((PASS + 2))
    P2P_AWARDED=1
fi

###############################################################################
# BEHAVIORAL — TSC-gated composite scores (16 pts)
###############################################################################

echo ""
echo "=== Test 9/9: TSC-gated behavioral composite ==="

if [ "$TSC_PASSED" -eq 1 ]; then
    # 9a (8 pts): tsc passes AND core refactoring done (>=2 of tests 1-4)
    if [ "$CORE_PASS" -ge 2 ]; then
        echo "  9a PASS: tsc + core refactoring verified ($CORE_PASS/4 core tests)"
        PASS=$((PASS + 8))
    else
        echo "  9a FAIL: tsc passes but core refactoring not done ($CORE_PASS/4 core tests)"
    fi

    # 9b (4 pts): tsc passes AND dead prop cleanup done (>=2 of tests 5-7)
    if [ "$CLEANUP_PASS" -ge 2 ]; then
        echo "  9b PASS: tsc + dead prop cleanup verified ($CLEANUP_PASS/3 cleanup tests)"
        PASS=$((PASS + 4))
    else
        echo "  9b FAIL: cleanup not verified ($CLEANUP_PASS/3 cleanup tests)"
    fi

    # 9c (2 pts): tsc passes AND full refactoring (core>=3 AND cleanup>=2)
    # This is a completeness bonus requiring both core and cleanup
    if [ "$CORE_PASS" -ge 3 ] && [ "$CLEANUP_PASS" -ge 2 ]; then
        echo "  9c PASS: tsc + full refactoring + cleanup verified"
        PASS=$((PASS + 2))
    else
        echo "  9c FAIL: incomplete (core=$CORE_PASS/4, cleanup=$CLEANUP_PASS/3)"
    fi
else
    echo "  9a/9b/9c SKIP: tsc failed — behavioral composite not awarded"
fi

###############################################################################
# Results
###############################################################################
echo ""
echo "================================"
echo "TSC: $([ $TSC_PASSED -eq 1 ] && echo 'PASS' || echo 'FAIL')"
echo "Core structural: $CORE_PASS/4 | Cleanup structural: $CLEANUP_PASS/3"
echo "P2P: $([ $P2P_AWARDED -eq 1 ] && echo 'awarded' || echo 'failed')"
echo "Results: $PASS / $TOTAL"
echo "================================"

REWARD=$(python3 -c "print(round(min(1.0, $PASS / $TOTAL), 2))")

echo "$REWARD" > "$REWARD_FILE"
echo "REWARD: $REWARD"
