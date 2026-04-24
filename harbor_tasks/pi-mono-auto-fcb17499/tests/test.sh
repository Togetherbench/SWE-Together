#!/bin/bash
set +e

# Verifier for pi-mono editor paddingX task
# Tests that the agent correctly:
# 1. TypeScript compiles (P2P)
# 2. Editor has padding getter/setter (F2P)
# 3. Setter triggers tui.requestRender() (F2P)
# 4. editorPadding in settings config (F2P)
# 5. Editor render() accounts for padding (F2P)

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
cd /workspace/pi-mono

SCORE=0

########################################################################
# Gate 1 (P2P): TypeScript compilation of tui package
# Weight: 0.10
# Passes on base commit AND after correct fix. Guards regressions.
########################################################################
echo "=== Gate 1 (P2P): TypeScript compilation ==="
npx tsgo -p packages/tui/tsconfig.build.json --noEmit 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: tui package compiles"
  SCORE=$((SCORE + 10))
else
  echo "FAIL: tui package does not compile"
fi

########################################################################
# Gate 2 (F2P): Editor class has padding getter/setter
# Weight: 0.20
# Fails on base (no padding methods), passes after fix.
# Accepts multiple naming conventions:
#   - getPaddingX/setPaddingX, getPadding/setPadding methods
#   - get paddingX / set paddingX accessors
########################################################################
echo "=== Gate 2 (F2P): Editor padding getter/setter ==="
cat > /tmp/test_gate2.ts << 'TSEOF'
import { Editor } from '/workspace/pi-mono/packages/tui/src/components/editor.js';

const proto = Editor.prototype;

// Check for method-style getter/setter (various naming conventions)
const methodNames = [
  ['getPaddingX', 'setPaddingX'],
  ['getPadding', 'setPadding'],
  ['getHorizontalPadding', 'setHorizontalPadding'],
];
let hasMethodStyle = false;
for (const [getter, setter] of methodNames) {
  if (typeof (proto as any)[getter] === 'function' && typeof (proto as any)[setter] === 'function') {
    hasMethodStyle = true;
    break;
  }
}

// Check for accessor-style (get/set paddingX or padding)
const accessorNames = ['paddingX', 'padding', 'horizontalPadding'];
let hasAccessorStyle = false;
for (const name of accessorNames) {
  const desc = Object.getOwnPropertyDescriptor(proto, name);
  if (desc && typeof desc.get === 'function' && typeof desc.set === 'function') {
    hasAccessorStyle = true;
    break;
  }
}

if (hasMethodStyle || hasAccessorStyle) {
  console.log('PASS: Editor has padding getter/setter');
  process.exit(0);
} else {
  console.log('FAIL: Editor missing padding getter/setter');
  process.exit(1);
}
TSEOF
bun run /tmp/test_gate2.ts 2>&1
if [ $? -eq 0 ]; then
  SCORE=$((SCORE + 20))
fi

########################################################################
# Gate 3 (F2P): Setting padding triggers tui.requestRender()
# Weight: 0.25
# Fails on base. The setter MUST call requestRender for re-render.
# This was explicitly requested by the user in the session.
########################################################################
echo "=== Gate 3 (F2P): Padding setter triggers requestRender ==="
cat > /tmp/test_gate3.ts << 'TSEOF'
import { Editor } from '/workspace/pi-mono/packages/tui/src/components/editor.js';

let renderRequested = false;
const mockTui = {
  terminal: { rows: 24, cols: 80 },
  requestRender: () => { renderRequested = true; },
} as any;

const mockTheme = {
  borderColor: (s: string) => s,
  activeBorderColor: (s: string) => s,
  textColor: (s: string) => s,
  cursorColor: (s: string) => s,
  selectedTextBg: (s: string) => s,
  lineNumberColor: (s: string) => s,
  scrollIndicator: (s: string) => s,
} as any;

const editor = new Editor(mockTui, mockTheme);

// Try all known setter patterns
const setterMethods = ['setPaddingX', 'setPadding', 'setHorizontalPadding'];
let setterCalled = false;

for (const methodName of setterMethods) {
  if (typeof (editor as any)[methodName] === 'function') {
    // Some setters take (x) some take (x, y)
    try { (editor as any)[methodName](2, 0); } catch { (editor as any)[methodName](2); }
    setterCalled = true;
    break;
  }
}

if (!setterCalled) {
  // Try accessor-style
  const accessorNames = ['paddingX', 'padding', 'horizontalPadding'];
  for (const name of accessorNames) {
    const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), name);
    if (desc && desc.set) {
      (editor as any)[name] = 2;
      setterCalled = true;
      break;
    }
  }
}

if (!setterCalled) {
  console.log('FAIL: no padding setter found');
  process.exit(1);
}

if (renderRequested) {
  console.log('PASS: padding setter triggers requestRender');
  process.exit(0);
} else {
  console.log('FAIL: padding setter did not trigger requestRender');
  process.exit(1);
}
TSEOF
bun run /tmp/test_gate3.ts 2>&1
if [ $? -eq 0 ]; then
  SCORE=$((SCORE + 25))
fi

########################################################################
# Gate 4 (F2P): Editor padding exists as a configurable setting
# Weight: 0.20
# Fails on base (no such setting), passes after adding it.
# Checks settings-selector, interactive-mode, and config for any
# padding-related setting name.
########################################################################
echo "=== Gate 4 (F2P): Editor padding in settings ==="
cat > /tmp/test_gate4.ts << 'TSEOF'
import { readFileSync } from 'fs';
import { join } from 'path';

const settingsDir = '/workspace/pi-mono/packages/coding-agent/src/modes/interactive/components';
const interactiveDir = '/workspace/pi-mono/packages/coding-agent/src/modes/interactive';

let found = false;
const filesToCheck = [
  join(settingsDir, 'settings-selector.ts'),
  join(interactiveDir, 'interactive-mode.ts'),
  '/workspace/pi-mono/packages/coding-agent/src/config.ts',
];

// Accept various naming for the setting
const settingPatterns = [
  'editorPaddingX', 'editorPadding', 'editor_padding',
  'EditorPadding', 'EDITOR_PADDING',
];

for (const f of filesToCheck) {
  try {
    const src = readFileSync(f, 'utf8');
    for (const pattern of settingPatterns) {
      if (src.includes(pattern)) {
        found = true;
        break;
      }
    }
    if (found) break;
  } catch {}
}

if (found) {
  console.log('PASS: editor padding found in settings/config');
  process.exit(0);
} else {
  console.log('FAIL: editor padding not found in settings/config');
  process.exit(1);
}
TSEOF
bun run /tmp/test_gate4.ts 2>&1
if [ $? -eq 0 ]; then
  SCORE=$((SCORE + 20))
fi

########################################################################
# Gate 5 (F2P): Editor render() incorporates padding in layout
# Weight: 0.25
# Fails on base. Verifies that setting padding actually affects render
# output - render with padding=0 vs padding=4 must produce different
# output.
########################################################################
echo "=== Gate 5 (F2P): render() uses padding ==="
cat > /tmp/test_gate5.ts << 'TSEOF'
import { Editor } from '/workspace/pi-mono/packages/tui/src/components/editor.js';

const mockTui = {
  terminal: { rows: 24, cols: 80 },
  requestRender: () => {},
} as any;

const mockTheme = {
  borderColor: (s: string) => s,
  activeBorderColor: (s: string) => s,
  textColor: (s: string) => s,
  cursorColor: (s: string) => s,
  selectedTextBg: (s: string) => s,
  lineNumberColor: (s: string) => s,
  scrollIndicator: (s: string) => s,
} as any;

const editor = new Editor(mockTui, mockTheme);
editor.focused = true;
editor.setText('hello world');

// Render with padding=0
const render0 = editor.render(40);

// Set padding using any available method
const setterMethods = ['setPaddingX', 'setPadding', 'setHorizontalPadding'];
let set = false;
for (const methodName of setterMethods) {
  if (typeof (editor as any)[methodName] === 'function') {
    try { (editor as any)[methodName](4, 0); } catch { (editor as any)[methodName](4); }
    set = true;
    break;
  }
}
if (!set) {
  const accessorNames = ['paddingX', 'padding', 'horizontalPadding'];
  for (const name of accessorNames) {
    const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), name);
    if (desc && desc.set) {
      (editor as any)[name] = 4;
      set = true;
      break;
    }
  }
}

if (!set) {
  console.log('FAIL: no padding setter to test render');
  process.exit(1);
}

// Render with padding=4
const render4 = editor.render(40);

const render0Str = render0.join('\n');
const render4Str = render4.join('\n');

if (render0Str !== render4Str) {
  console.log('PASS: render() output changes with padding');
  process.exit(0);
} else {
  console.log('FAIL: render() output identical regardless of padding');
  process.exit(1);
}
TSEOF
bun run /tmp/test_gate5.ts 2>&1
if [ $? -eq 0 ]; then
  SCORE=$((SCORE + 25))
fi

########################################################################
# Final score
########################################################################
echo ""
echo "=== RESULTS ==="

WHOLE=$((SCORE / 100))
FRAC=$((SCORE % 100))
if [ $FRAC -lt 10 ]; then
  REWARD="${WHOLE}.0${FRAC}"
else
  REWARD="${WHOLE}.${FRAC}"
fi

echo "Score: $REWARD / 1.00"
echo "$REWARD" > "$REWARD_FILE"
echo "Reward written to $REWARD_FILE: $REWARD"
