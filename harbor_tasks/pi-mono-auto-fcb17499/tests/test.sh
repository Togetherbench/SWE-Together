#!/bin/bash
set +e

# Verifier for pi-mono PR review task: PR #791 introduces editor padding changes.
# The user asked to verify rendering and hardware cursor positioning are not broken.
# A good review identifies the actual bug introduced by the PR or its surrounding code:
# When a settings change triggers a render via setPaddingX (or similar setter),
# the editor loses focus / cannot be typed in until the panel is reopened.
# The fix: ensure the showSelector done() closure (or equivalent path) calls
# requestRender after restoring focus, OR setters that call requestRender don't
# break focus handling.
#
# We don't need the agent to "fix" code per se - it's a review task. But all 5
# agents made code edits anyway. We score on:
#   1. Repo still builds (P2P regression guard)
#   2. Editor still has padding API (P2P - PR introduced it, must remain)
#   3. Padding setter triggers a render (behavioral)
#   4. Render output actually changes when padding changes (behavioral)
#   5. The done() closure in showSelector calls requestRender (the actual fix)
#   6. Hardware cursor positioning math accounts for paddingX (behavioral)

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO=/workspace/pi-mono
if [ ! -d "$REPO" ]; then
  for d in /workspace/*/; do
    if [ -d "$d/packages/tui" ]; then REPO="${d%/}"; break; fi
  done
fi

if [ ! -d "$REPO/packages/tui" ]; then
  echo "FATAL: cannot find pi-mono repo"
  echo "0.0" > "$REWARD_FILE"
  exit 0
fi

cd "$REPO" || { echo "0.0" > "$REWARD_FILE"; exit 0; }

BUN="$(command -v bun)"
if [ -z "$BUN" ]; then BUN="/root/.bun/bin/bun"; fi
if [ ! -x "$BUN" ]; then
  echo "FATAL: bun not found"
  echo "0.0" > "$REWARD_FILE"
  exit 0
fi

EDITOR_FILE="$REPO/packages/tui/src/components/editor.ts"
INTERACTIVE_FILE="$REPO/packages/coding-agent/src/modes/interactive/interactive-mode.ts"

SCORE=0
MAX=100

############################################################
# Gate 1 (P2P, 15%): tui package typechecks
############################################################
echo "=== Gate 1 (P2P, 15%): tui typecheck ==="
G1=0
TC_OUT=$(cd "$REPO" && npx -y tsgo -p packages/tui/tsconfig.build.json --noEmit 2>&1)
TC_RC=$?
if [ $TC_RC -ne 0 ]; then
  # fallback to tsc
  TC_OUT=$(cd "$REPO" && npx -y typescript@5 tsc -p packages/tui/tsconfig.build.json --noEmit 2>&1)
  TC_RC=$?
fi
if [ $TC_RC -eq 0 ]; then
  echo "PASS: tui typechecks"
  G1=15
else
  echo "FAIL: tui typecheck failed"
  echo "$TC_OUT" | tail -30
fi
SCORE=$((SCORE + G1))

############################################################
# Gate 2 (P2P, 10%): Editor still exports & has paddingX API
# (any of: get/setPaddingX methods, or paddingX accessor, or
# paddingX field reachable via constructor option)
############################################################
echo "=== Gate 2 (P2P, 10%): Editor paddingX API exists ==="
G2=0
cat > /tmp/g2.ts << 'TSEOF'
import { Editor } from REPLACE_PATH;
const proto: any = (Editor as any).prototype;
const desc = Object.getOwnPropertyDescriptor(proto, 'paddingX');
const hasAccessor = !!(desc && (desc.get || desc.set));
const hasMethods = typeof proto.getPaddingX === 'function' && typeof proto.setPaddingX === 'function';
if (hasAccessor || hasMethods) { console.log('OK'); process.exit(0); }
console.log('NO PADDINGX API');
process.exit(1);
TSEOF
sed -i "s|REPLACE_PATH|'$EDITOR_FILE'|" /tmp/g2.ts
G2_OUT=$("$BUN" run /tmp/g2.ts 2>&1)
if echo "$G2_OUT" | grep -q "^OK$"; then
  echo "PASS: paddingX API present"
  G2=10
else
  echo "FAIL: $G2_OUT"
fi
SCORE=$((SCORE + G2))

############################################################
# Gate 3 (F2P, 25%): Setting padding triggers requestRender
# AND value is actually stored (round-trip).
############################################################
echo "=== Gate 3 (F2P, 25%): padding setter triggers render & stores value ==="
G3=0
cat > /tmp/g3.ts << 'TSEOF'
import { Editor } from REPLACE_PATH;

let renderCount = 0;
const tui: any = {
  terminal: { rows: 24, cols: 80 },
  requestRender: () => { renderCount++; },
};
const id = (s: string) => s;
const theme: any = new Proxy({}, { get: () => id });

let editor: any;
try { editor = new (Editor as any)(tui, theme); }
catch (e) { console.log('CTOR_FAIL', String(e)); process.exit(2); }

const baseRender = renderCount;

// Try to set padding
let didSet = false;
if (typeof editor.setPaddingX === 'function') {
  editor.setPaddingX(5);
  didSet = true;
} else {
  const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), 'paddingX');
  if (desc && desc.set) { editor.paddingX = 5; didSet = true; }
}
if (!didSet) { console.log('NO_SETTER'); process.exit(3); }

const renderTriggered = renderCount > baseRender;

// Round-trip
let got: any;
if (typeof editor.getPaddingX === 'function') got = editor.getPaddingX();
else got = editor.paddingX;

const stored = (got === 5);

console.log(JSON.stringify({ renderTriggered, stored, renderCount, got }));
process.exit(0);
TSEOF
sed -i "s|REPLACE_PATH|'$EDITOR_FILE'|" /tmp/g3.ts
G3_OUT=$("$BUN" run /tmp/g3.ts 2>&1)
echo "$G3_OUT"
if echo "$G3_OUT" | grep -q '"renderTriggered":true' && echo "$G3_OUT" | grep -q '"stored":true'; then
  echo "PASS: setter triggers render and stores value"
  G3=25
elif echo "$G3_OUT" | grep -q '"stored":true'; then
  echo "PARTIAL: stores but does not trigger render"
  G3=10
fi
SCORE=$((SCORE + G3))

############################################################
# Gate 4 (F2P, 20%): render() output reflects paddingX
# Different padding -> different rendered text width / content
############################################################
echo "=== Gate 4 (F2P, 20%): render() actually uses paddingX ==="
G4=0
cat > /tmp/g4.ts << 'TSEOF'
import { Editor } from REPLACE_PATH;

const tui: any = { terminal: { rows: 24, cols: 80 }, requestRender: () => {} };
const id = (s: string) => s;
const theme: any = new Proxy({}, { get: () => id });

function makeEditor() {
  const e: any = new (Editor as any)(tui, theme);
  if (typeof e.focused !== 'undefined') {
    try { e.focused = true; } catch {}
  }
  if (typeof e.setText === 'function') e.setText('hello world');
  return e;
}

function setPad(e: any, v: number) {
  if (typeof e.setPaddingX === 'function') { e.setPaddingX(v); return true; }
  const d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e), 'paddingX');
  if (d && d.set) { e.paddingX = v; return true; }
  return false;
}

function render(e: any, w: number): string {
  // try render(width) signature; fallback to render({width})
  try {
    const r = e.render(w);
    if (typeof r === 'string') return r;
    if (Array.isArray(r)) return r.join('\n');
    if (r && typeof r === 'object' && Array.isArray(r.lines)) return r.lines.join('\n');
    return JSON.stringify(r);
  } catch (err) {
    return 'ERR:' + String(err);
  }
}

const e0 = makeEditor();
setPad(e0, 0);
const out0 = render(e0, 40);

const e4 = makeEditor();
setPad(e4, 4);
const out4 = render(e4, 40);

const differ = out0 !== out4 && out0.length > 0 && out4.length > 0 && !out0.startsWith('ERR:') && !out4.startsWith('ERR:');
console.log(JSON.stringify({ differ, len0: out0.length, len4: out4.length }));
process.exit(differ ? 0 : 1);
TSEOF
sed -i "s|REPLACE_PATH|'$EDITOR_FILE'|" /tmp/g4.ts
G4_OUT=$("$BUN" run /tmp/g4.ts 2>&1)
echo "$G4_OUT"
if echo "$G4_OUT" | grep -q '"differ":true'; then
  echo "PASS: render output depends on paddingX"
  G4=20
fi
SCORE=$((SCORE + G4))

############################################################
# Gate 5 (F2P, 20%): The actual focus/render bug fix.
# After settings change, when showSelector's done() closure runs,
# it must call requestRender so the editor re-displays correctly.
# We verify behaviorally by reading interactive-mode.ts and checking
# that the done() closure inside showSelector contains a requestRender
# call (this is the documented fix mentioned by multiple agents).
# We accept ANY approach that ensures done() ends in a render:
#   - explicit this.ui.requestRender() inside done()
#   - or a setter on editor (e.g. focused/borderColor) that itself
#     calls tui.requestRender (MiniMax approach)
############################################################
echo "=== Gate 5 (F2P, 20%): done() closure causes a render ==="
G5=0
if [ -f "$INTERACTIVE_FILE" ]; then
  # Extract the showSelector method body (lines from 'showSelector' to next method or '}')
  SHOW_BLOCK=$(awk '
    /private showSelector/ { capture=1; depth=0 }
    capture {
      print
      n=gsub(/\{/,"{"); depth+=n
      n=gsub(/\}/,"}"); depth-=n
      if (depth<=0 && /\}/) { capture=0 }
    }
  ' "$INTERACTIVE_FILE")

  # Look for done = () => { ... requestRender ... }
  DONE_BLOCK=$(echo "$SHOW_BLOCK" | awk '
    /const done[[:space:]]*=/ { capture=1; depth=0 }
    capture {
      print
      n=gsub(/\{/,"{"); depth+=n
      n=gsub(/\}/,"}"); depth-=n
      if (depth<=0 && /\};/) { capture=0 }
    }
  ')

  if echo "$DONE_BLOCK" | grep -q "requestRender"; then
    echo "PASS: done() closure calls requestRender directly"
    G5=20
  else
    # Accept indirect render-trigger via setter (MiniMax style):
    # An editor setter that fires requestRender on assignment, where
    # done() reassigns it. We check editor.ts for a setter that calls
    # this.tui.requestRender() AND interactive-mode.ts done()-area
    # assigns to that property.
    SETTER_PROPS=$(awk '
      /set [a-zA-Z_][a-zA-Z0-9_]*\(/ {
        # capture property name
        match($0, /set [a-zA-Z_][a-zA-Z0-9_]*/)
        name=substr($0, RSTART+4, RLENGTH-4)
        capture=1; depth=0; body=""
      }
      capture {
        body=body $0 "\n"
        n=gsub(/\{/,"{"); depth+=n
        n=gsub(/\}/,"}"); depth-=n
        if (depth<=0 && /\}/) {
          if (body ~ /requestRender/) print name
          capture=0; body=""
        }
      }
    ' "$EDITOR_FILE")

    INDIRECT=0
    if [ -n "$SETTER_PROPS" ]; then
      while IFS= read -r prop; do
        [ -z "$prop" ] && continue
        if echo "$DONE_BLOCK" | grep -E "(this\.editor|this\.defaultEditor)\.$prop[[:space:]]*=" > /dev/null; then
          INDIRECT=1
          echo "PASS: done() triggers render indirectly via setter '$prop'"
          break
        fi
      done <<< "$SETTER_PROPS"
    fi
    if [ $INDIRECT -eq 1 ]; then
      G5=20
    else
      echo "FAIL: done() closure does not cause a render"
    fi
  fi
else
  echo "SKIP: interactive-mode.ts missing"
fi
SCORE=$((SCORE + G5))

############################################################
# Gate 6 (F2P, 10%): Hardware cursor / render math respects padding
# Read render() in editor.ts: it must reference the padding value
# when computing layout (any of: paddingX, _paddingX, this.paddingX).
############################################################
echo "=== Gate 6 (F2P, 10%): render() math uses padding ==="
G6=0
RENDER_BLOCK=$(awk '
  /^[[:space:]]*render[[:space:]]*\(/ && !/=>/ { capture=1; depth=0 }
  capture {
    print
    n=gsub(/\{/,"{"); depth+=n
    n=gsub(/\}/,"}"); depth-=n
    if (depth<=0 && /\}/) { capture=0 }
  }
' "$EDITOR_FILE")

if echo "$RENDER_BLOCK" | grep -E "(this\._paddingX|this\.paddingX|paddingX)" > /dev/null; then
  if echo "$RENDER_BLOCK" | grep -E "(width[[:space:]]*-[[:space:]]*[^;]*padding|padding[^;]*\*[[:space:]]*2|maxPadding|width[[:space:]]*-[[:space:]]*paddingX)" > /dev/null; then
    echo "PASS: render math incorporates paddingX"
    G6=10
  else
    echo "PARTIAL: render references paddingX but math unclear"
    G6=5
  fi
else
  echo "FAIL: render does not reference paddingX"
fi
SCORE=$((SCORE + G6))

############################################################
# Final
############################################################
echo "==============================="
echo "Score: $SCORE / $MAX"
echo "  Gate1 (typecheck):      $G1 / 15"
echo "  Gate2 (paddingX API):   $G2 / 10"
echo "  Gate3 (setter+render):  $G3 / 25"
echo "  Gate4 (render uses pad):$G4 / 20"
echo "  Gate5 (done() renders): $G5 / 20"
echo "  Gate6 (render math):    $G6 / 10"

REWARD=$(awk -v s="$SCORE" -v m="$MAX" 'BEGIN{ printf "%.3f", s/m }')
echo "Reward: $REWARD"
echo "$REWARD" > "$REWARD_FILE"
exit 0