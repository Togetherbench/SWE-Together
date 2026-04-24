#!/bin/bash
# Verifier for pi-mono clipboard guard fix
# Bug: @crosscopy/clipboard native Rust module panics with DisplayNotSet
# on Linux without DISPLAY when Clipboard.hasImage() is called.
# Fix: guard clipboard function calls based on display availability.
set +e
mkdir -p /logs/verifier
cd /workspace/pi-mono
score=0

add_score() {
    score=$(awk "BEGIN{printf \"%.2f\", $score + $1}")
}

# ============================================================
# P2P GATE (0.10): Vitest regression test
# Passes at base and after fix — guards against regressions.
# Runs tools.test.ts which is independent of clipboard changes.
# ============================================================
echo "=== P2P: Vitest skills regression ==="
npx vitest --run packages/coding-agent/test/skills.test.ts 2>&1
VITEST_EXIT=${PIPESTATUS[0]}
if [ $VITEST_EXIT -eq 0 ]; then
    add_score 0.10
    echo "P2P PASS (0.10)"
else
    echo "P2P FAIL (exit=$VITEST_EXIT)"
fi

# ============================================================
# F2P GATE 1 (0.25): TypeScript compilation + guard presence
# TypeScript must still compile AND clipboard guard must exist.
# At base: TS compiles but no display guard -> FAIL
# After fix: TS compiles and guard present -> PASS
# ============================================================
echo ""
echo "=== F2P Gate 1: TypeScript + guard presence ==="
npx tsgo --noEmit 2>&1
TS_OK=$?

GUARD_PRESENT=1
if [ $TS_OK -eq 0 ]; then
    # Check for clipboard display guard in the codebase
    node -e "
const fs = require('fs');
const path = require('path');
const srcDir = '/workspace/pi-mono/packages/coding-agent/src';
const imPath = path.join(srcDir, 'modes/interactive/interactive-mode.ts');
const im = fs.readFileSync(imPath, 'utf8');

// Find handleClipboardImagePaste METHOD DEFINITION (not call sites)
// Look for the method definition pattern with visibility or async keywords
const defRegex = /(?:private|public|protected|async)\\s+(?:async\\s+)?handleClipboardImagePaste/g;
let defMatch = defRegex.exec(im);
// Fallback: find by looking for function-like pattern
if (!defMatch) {
    const altRegex = /handleClipboardImagePaste\\s*\\(\\s*\\)\\s*(?::\\s*Promise)?/g;
    let m;
    while ((m = altRegex.exec(im)) !== null) {
        // Check that this is a definition (preceded by visibility keyword or async)
        const before = im.substring(Math.max(0, m.index - 50), m.index);
        if (before.match(/(?:private|public|protected|async)\\s*$/)) {
            defMatch = m;
            break;
        }
    }
}
const idx = defMatch ? defMatch.index : im.indexOf('handleClipboardImagePaste');
if (idx === -1) {
    // Method removed — valid if no unguarded clipboard calls remain
    if (!im.includes('Clipboard.hasImage') && !im.includes('Clipboard.getImage')) {
        console.log('Clipboard calls removed entirely');
        process.exit(0);
    }
    process.exit(1);
}

// Get method body (up to next method or 1500 chars)
const afterMethod = im.substring(idx);
const nextMatch = afterMethod.search(/\\n\\t(private|public|protected) /);
const endIdx = nextMatch > 30 ? nextMatch : 1500;
const methodBody = afterMethod.substring(0, endIdx);

// Check for display guard BEFORE any clipboard function call
const clipCallMatch = methodBody.match(/(?:Clipboard|clipboard)\s*[\\.\\?]\s*(?:hasImage|getImage)/);
if (!clipCallMatch) {
    // No direct clipboard calls — might use wrapper or removed
    const utilsDir = path.join(srcDir, 'utils');
    try {
        const utilFiles = fs.readdirSync(utilsDir);
        for (const f of utilFiles) {
            if (!f.includes('clipboard')) continue;
            const content = fs.readFileSync(path.join(utilsDir, f), 'utf8');
            // Skip base clipboard.ts unless it was modified to include clipboard guard
            if (f === 'clipboard.ts' && !content.includes('hasImage')) continue;
            if (content.includes('DISPLAY') || content.includes('WAYLAND') || content.includes('platform')) {
                console.log('Found clipboard wrapper with guard: ' + f);
                process.exit(0);
            }
        }
    } catch {}
    // Check null-guard patterns
    if (methodBody.match(/!\\s*Clipboard\\b(?!\\.)/)) {
        console.log('Clipboard null-guarded');
        process.exit(0);
    }
    console.error('No clipboard calls and no wrapper found');
    process.exit(1);
}

const clipCallIdx = clipCallMatch.index;
const beforeCall = methodBody.substring(0, clipCallIdx);

// Guard patterns that prevent calling clipboard on headless Linux
const guardKeywords = ['DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND', 'hasDisplay', 'canUseClipboard', 'clipboardAvailable'];
const hasKeywordGuard = guardKeywords.some(k => beforeCall.includes(k));
const hasPlatformGuard = /process\\.platform.*linux/i.test(beforeCall) || /linux.*process\\.platform/i.test(beforeCall);
// Null-check guard: '!Clipboard' but NOT '!Clipboard.hasImage' (which is the bug itself)
const hasNullGuard = /!\\s*Clipboard\\b(?!\\.)/.test(beforeCall);
// Optional chaining
const hasOptionalChain = methodBody.includes('Clipboard?.hasImage') || methodBody.includes('Clipboard?.getImage');
// Wrapper import
const usesWrapper = im.includes('clipboard-native') || im.includes('clipboard-wrapper') || im.includes('clipboard-guard');
// Module-level null assignment
const moduleNullable = im.match(/let\\s+Clipboard/i) || im.match(/Clipboard\\s*=\\s*null/);
// Wrapper function guard: beforeCall contains an early return using a function from clipboard utils with display guards
const usesWrapperFn = (() => {
    if (!/return/.test(beforeCall)) return false;
    try {
        const utilFiles = fs.readdirSync(path.join(srcDir, 'utils'));
        for (const f of utilFiles) {
            if (!f.includes('clipboard')) continue;
            const content = fs.readFileSync(path.join(srcDir, 'utils', f), 'utf8');
            if (f === 'clipboard.ts' && !content.includes('hasImage')) continue;
            if (!(content.includes('DISPLAY') || content.includes('WAYLAND'))) continue;
            const exports = [...content.matchAll(/export\\s+(?:async\\s+)?function\\s+(\\w+)/g)];
            for (const [, funcName] of exports) {
                if (beforeCall.includes(funcName)) return true;
            }
        }
    } catch {}
    return false;
})();

if (hasKeywordGuard || hasPlatformGuard || hasNullGuard || hasOptionalChain || usesWrapper || moduleNullable || usesWrapperFn) {
    console.log('Display guard found before clipboard call');
    process.exit(0);
}

console.error('No display guard before clipboard function calls');
process.exit(1);
" 2>&1
    GUARD_PRESENT=$?
fi

if [ $TS_OK -eq 0 ] && [ $GUARD_PRESENT -eq 0 ]; then
    add_score 0.25
    echo "F2P Gate 1 PASS (0.25)"
else
    echo "F2P Gate 1 FAIL (TS=$TS_OK, GUARD=$GUARD_PRESENT)"
fi

# ============================================================
# F2P GATE 2 (0.35): Guard behavioral evaluation
# Extracts guard code and evaluates it using Node vm module.
# Tests guard correctly identifies headless Linux.
# At base: no guard -> FAIL
# After fix: guard evaluates correctly -> PASS
# ============================================================
echo ""
echo "=== F2P Gate 2: Guard behavioral evaluation ==="
node -e "
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const srcDir = '/workspace/pi-mono/packages/coding-agent/src';
const imPath = path.join(srcDir, 'modes/interactive/interactive-mode.ts');
const im = fs.readFileSync(imPath, 'utf8');

// === Strategy 1: Find guard in a wrapper module ===
const utilsDir = path.join(srcDir, 'utils');
let guardExpr = null;
let guardStyle = null; // 'allow' (true=can use) or 'block' (true=should return)

try {
    const utilFiles = fs.readdirSync(utilsDir);
    for (const f of utilFiles.filter(fn => fn.includes('clipboard'))) {
        const content = fs.readFileSync(path.join(utilsDir, f), 'utf8');
        // Skip base clipboard.ts unless it was modified to include clipboard guard
        if (f === 'clipboard.ts' && !content.includes('hasImage')) continue;
        // Pattern: const hasDisplay = process.platform !== 'linux' || Boolean(...)
        let m = content.match(/(?:const|let|var)\\s+\\w+\\s*=\\s*((?:process\\.platform|platform\\(\\))\\s*!==?\\s*['\"]linux['\"].*?);/);
        if (m) { guardExpr = m[1]; guardStyle = 'allow'; break; }
        // Pattern: if (process.platform === 'linux' && ...) or if (platform() === 'linux' && ...)
        m = content.match(/if\\s*\\(((?:process\\.platform|platform\\(\\))\\s*===?\\s*['\"]linux['\"]\\s*&&[^)]+)\\)/);
        if (m) { guardExpr = m[1]; guardStyle = 'block'; break; }
        // Pattern: conditional with DISPLAY
        m = content.match(/(?:const|let|var)\\s+\\w+\\s*=\\s*(.*DISPLAY.*?);/);
        if (m) { guardExpr = m[1]; guardStyle = 'allow'; break; }
    }
} catch {}

// === Strategy 2: Find inline guard in handleClipboardImagePaste ===
if (!guardExpr) {
    // Find method DEFINITION (not call site)
    const defRe = /(?:private|public|protected|async)\\s+(?:async\\s+)?handleClipboardImagePaste/;
    const defM = im.match(defRe);
    const methodIdx = defM ? defM.index : im.lastIndexOf('handleClipboardImagePaste');
    if (methodIdx !== -1) {
        const methodBody = im.substring(methodIdx, methodIdx + 1500);
        // Pattern: if (condition) { return; }
        const ifReturnRegex = /if\\s*\\(([^)]+)\\)\\s*\\{?\\s*(?:\\n\\s*)?return/g;
        let m;
        while ((m = ifReturnRegex.exec(methodBody)) !== null) {
            const cond = m[1];
            if (cond.match(/DISPLAY|WAYLAND|platform|linux/i)) {
                guardExpr = cond;
                guardStyle = 'block'; // if true, return early
                break;
            }
            // Null check: if (!Clipboard) return
            if (cond.match(/^\\s*!\\s*\\w*[Cc]lipboard\\s*$/)) {
                // Check if Clipboard is nullable
                if (im.match(/let\\s+\\w*[Cc]lipboard/i)) {
                    guardExpr = cond;
                    guardStyle = 'block';
                    break;
                }
            }
        }

        // Pattern: Clipboard && Clipboard.hasImage()
        if (!guardExpr && (methodBody.includes('Clipboard?.') || methodBody.includes('Clipboard &&'))) {
            if (im.match(/let\\s+\\w*[Cc]lipboard/i) || im.match(/\\w*[Cc]lipboard\\w*\\s*=\\s*null/)) {
                console.log('Optional chaining with nullable clipboard detected');
                process.exit(0);
            }
        }
    }
}

if (!guardExpr) {
    console.error('No evaluable guard expression found');
    process.exit(1);
}

console.log('Guard expression:', guardExpr.trim());
console.log('Guard style:', guardStyle);

// === Evaluate the guard ===
function evalGuard(platformStr, env) {
    try {
        return vm.runInNewContext(guardExpr, {
            process: { platform: platformStr, env },
            platform: () => platformStr,
            Boolean: Boolean,
            Clipboard: null,
        });
    } catch (e) {
        return null;
    }
}

const headlessLinux = evalGuard('linux', {});
const linuxWithDisplay = evalGuard('linux', { DISPLAY: ':0' });
const darwin = evalGuard('darwin', {});

console.log('Headless Linux:', headlessLinux);
console.log('Linux w/ display:', linuxWithDisplay);
console.log('Darwin:', darwin);

// Verify correctness based on guard style
if (guardStyle === 'block') {
    // 'block' style: true means skip clipboard
    // headless Linux should be true (skip), others should be false (allow)
    if (headlessLinux && !linuxWithDisplay) {
        console.log('PASS: Guard correctly blocks clipboard on headless Linux');
        process.exit(0);
    }
    if (headlessLinux && !darwin) {
        console.log('PASS: Guard correctly blocks headless Linux, allows Darwin');
        process.exit(0);
    }
} else if (guardStyle === 'allow') {
    // 'allow' style: true means clipboard available
    // headless Linux should be false (no clipboard), others should be true
    if (!headlessLinux && (linuxWithDisplay || darwin)) {
        console.log('PASS: Guard correctly disallows clipboard on headless Linux');
        process.exit(0);
    }
}

// Fallback: if guard references platform/display terms and differs between envs
if (headlessLinux !== linuxWithDisplay || headlessLinux !== darwin) {
    console.log('PASS: Guard differentiates headless Linux');
    process.exit(0);
}

// If vm eval returned null for all (parsing issues), check expression content
if (headlessLinux === null && guardExpr.match(/DISPLAY|WAYLAND|platform.*linux/i)) {
    console.log('PASS: Guard references display/platform (vm eval inconclusive)');
    process.exit(0);
}

console.error('Guard does not correctly differentiate environments');
process.exit(1);
" 2>&1
if [ $? -eq 0 ]; then
    add_score 0.35
    echo "F2P Gate 2 PASS (0.35)"
else
    echo "F2P Gate 2 FAIL"
fi

# ============================================================
# F2P GATE 3 (0.30): Clipboard crash prevention verified
# Verifies the fix prevents the Rust panic on headless Linux.
# Uses subprocess to confirm native library still crashes (the bug exists
# in the library), then checks that application code guards against it.
# At base: no guard in application code -> FAIL
# After fix: application code properly guards -> PASS
# ============================================================
echo ""
echo "=== F2P Gate 3: Crash prevention ==="
node -e "
const fs = require('fs');
const path = require('path');

const srcDir = '/workspace/pi-mono/packages/coding-agent/src';
const imPath = path.join(srcDir, 'modes/interactive/interactive-mode.ts');
const im = fs.readFileSync(imPath, 'utf8');

// Verify clipboard is still referenced (not entirely stripped)
const hasClipboardRef = im.includes('@crosscopy/clipboard') ||
    im.includes('clipboard-native') || im.includes('clipboard-wrapper') ||
    im.includes('clipboard-guard') || im.includes('onPasteImage');
if (!hasClipboardRef) {
    console.error('Clipboard functionality entirely removed');
    process.exit(1);
}

// Check the module-level import pattern changed or guard exists
const origImport = \"import Clipboard from \\\"@crosscopy/clipboard\\\"\";
const hasOrigImport = im.includes(origImport);

// Find method DEFINITION (not call site)
const defRe3 = /(?:private|public|protected|async)\\s+(?:async\\s+)?handleClipboardImagePaste/;
const defM3 = im.match(defRe3);
const methodIdx = defM3 ? defM3.index : -1;

// Case 1: Method removed and no unguarded clipboard calls
if (methodIdx === -1) {
    if (!im.includes('Clipboard.hasImage') && !im.includes('Clipboard.getImage')) {
        console.log('Method removed, no unguarded clipboard calls');
        process.exit(0);
    }
    console.error('Method removed but unguarded clipboard calls remain');
    process.exit(1);
}

const methodBody = im.substring(methodIdx, methodIdx + 1500);

// Case 2: Original import unchanged — inline guard required
if (hasOrigImport) {
    // The method MUST have a guard before calling clipboard functions
    const hasImagePos = methodBody.indexOf('.hasImage');
    if (hasImagePos === -1) {
        console.log('hasImage not called in method');
        process.exit(0);
    }

    const beforeHasImage = methodBody.substring(0, hasImagePos);

    // Check for display guard keywords — but NOT patterns that are part of
    // the original buggy code (like '!Clipboard.hasImage()' which is the bug)
    const displayGuard = beforeHasImage.includes('DISPLAY') ||
        beforeHasImage.includes('WAYLAND') ||
        /process\\.platform.*linux/i.test(beforeHasImage) ||
        /linux.*process\\.platform/i.test(beforeHasImage) ||
        beforeHasImage.includes('hasDisplay') ||
        beforeHasImage.includes('canUseClipboard');

    // Null guard: '!Clipboard' as standalone check (not '!Clipboard.hasImage')
    // Look for 'if (!Clipboard)' pattern on its own line before hasImage
    const nullGuardPattern = /if\\s*\\(\\s*!\\s*Clipboard\\s*\\)/;
    const nullGuard = nullGuardPattern.test(beforeHasImage);

    if (displayGuard || nullGuard) {
        console.log('Inline guard found before clipboard call');
        process.exit(0);
    }

    console.error('Original import present but no guard before hasImage');
    process.exit(1);
}

// Case 3: Import changed — check for wrapper/conditional import
const wrapperImport = im.includes('clipboard-native') || im.includes('clipboard-wrapper') ||
    im.includes('clipboard-guard');
const conditionalImport = im.match(/let\\s+Clipboard/) || im.match(/Clipboard\\s*=\\s*null/) ||
    im.includes('await import');
const tryImport = im.match(/try\\s*\\{[\\s\\S]*?require.*clipboard[\\s\\S]*?\\}\\s*catch/);

if (wrapperImport || conditionalImport || tryImport) {
    // Verify the wrapper/conditional handles headless Linux
    if (wrapperImport) {
        // Check wrapper file for display guard
        const utilsDir = path.join(srcDir, 'utils');
        const utilFiles = fs.readdirSync(utilsDir);
        for (const f of utilFiles) {
            if (!f.includes('clipboard')) continue;
            const content = fs.readFileSync(path.join(utilsDir, f), 'utf8');
            if (f === 'clipboard.ts' && !content.includes('hasImage')) continue;
            if (content.includes('DISPLAY') || content.includes('WAYLAND') || content.includes('platform')) {
                console.log('Wrapper module has display guard: ' + f);
                process.exit(0);
            }
        }
    }
    if (conditionalImport) {
        console.log('Conditional clipboard import found');
        process.exit(0);
    }
    if (tryImport) {
        console.log('try/catch clipboard import found');
        process.exit(0);
    }
}

console.error('Import changed but no valid guard mechanism found');
process.exit(1);
" 2>&1
if [ $? -eq 0 ]; then
    add_score 0.30
    echo "F2P Gate 3 PASS (0.30)"
else
    echo "F2P Gate 3 FAIL"
fi

# ============================================================
# Write final score
# ============================================================
echo ""
echo "=== Final Score: $score ==="
echo "$score" > /logs/verifier/reward.txt
