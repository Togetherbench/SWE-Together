#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD="0.0"
echo "$REWARD" > "$REWARD_FILE"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

cd /workspace/pi-mono 2>/dev/null || {
    echo "FATAL: /workspace/pi-mono missing"
    echo "0.0" > "$REWARD_FILE"
    exit 0
}

command -v node >/dev/null 2>&1 || { echo "FATAL: node missing"; echo "0.0" > "$REWARD_FILE"; exit 0; }

TUI_DIR="packages/tui"
TI_FILE="$TUI_DIR/src/terminal-image.ts"
TUI_FILE="$TUI_DIR/src/tui.ts"
MD_FILE="$TUI_DIR/src/components/markdown.ts"
BOX_FILE="$TUI_DIR/src/components/box.ts"
TI_TEST="$TUI_DIR/test/terminal-image.test.ts"

for f in "$TI_FILE" "$TUI_FILE" "$MD_FILE" "$BOX_FILE"; do
    [ -f "$f" ] || { echo "FATAL: $f missing"; echo "0.0" > "$REWARD_FILE"; exit 0; }
done

# ============================================================
# P2P GATES (gating only)
# ============================================================

# (a) No unresolved merge conflict markers
for f in "$TI_FILE" "$TUI_FILE" "$MD_FILE" "$BOX_FILE"; do
    if grep -qE '^(<<<<<<< |>>>>>>> |=======$)' "$f"; then
        echo "GATE FAIL: unresolved merge conflict markers in $f"
        echo "0.0" > "$REWARD_FILE"
        exit 0
    fi
done

# (b) tui.ts must parse/import successfully via tsx
node --import tsx -e "import('./$TUI_FILE').then(()=>{console.log('OK')}).catch(e=>{console.error(e.message);process.exit(1)})" >/tmp/parse.out 2>&1
if [ $? -ne 0 ] || ! grep -q OK /tmp/parse.out; then
    echo "GATE FAIL: tui.ts does not parse/import"
    cat /tmp/parse.out | head -20
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# (c) terminal-image.ts must parse/import
node --import tsx -e "import('./$TI_FILE').then(()=>{console.log('OK')}).catch(e=>{console.error(e.message);process.exit(1)})" >/tmp/parse2.out 2>&1
if [ $? -ne 0 ] || ! grep -q OK /tmp/parse2.out; then
    echo "GATE FAIL: terminal-image.ts does not parse/import"
    cat /tmp/parse2.out | head -20
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# (d) markdown.ts must parse/import
node --import tsx -e "import('./$MD_FILE').then(()=>{console.log('OK')}).catch(e=>{console.error(e.message);process.exit(1)})" >/tmp/parse3.out 2>&1
if [ $? -ne 0 ] || ! grep -q OK /tmp/parse3.out; then
    echo "GATE FAIL: markdown.ts does not parse/import"
    cat /tmp/parse3.out | head -20
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# (e) box.ts must parse/import
node --import tsx -e "import('./$BOX_FILE').then(()=>{console.log('OK')}).catch(e=>{console.error(e.message);process.exit(1)})" >/tmp/parse4.out 2>&1
if [ $? -ne 0 ] || ! grep -q OK /tmp/parse4.out; then
    echo "GATE FAIL: box.ts does not parse/import"
    cat /tmp/parse4.out | head -20
    echo "0.0" > "$REWARD_FILE"
    exit 0
fi

# ============================================================
# F2P scoring — total weight = 1.00
# Six gates probing different slices of correctness.
# ============================================================

# Use awk to do float math
add_to_earned() {
    EARNED=$(awk -v e="$EARNED" -v w="$1" 'BEGIN{printf "%.4f", e+w}')
}

EARNED="0.0000"
TOTAL="1.0000"

emit() {
    local pass=$1 w=$2 label=$3
    if [ "$pass" = "1" ]; then
        add_to_earned "$w"
        echo "  [+$w] $label"
    else
        echo "  [ 0 /$w] $label"
    fi
}

# ---------- F2P #1 (0.09): isImageLine export REMOVED from terminal-image.ts ----------
echo ""
echo "=== F2P 1 (0.09): isImageLine export removed ==="
RES1=$(node --import tsx -e "
import('./$TI_FILE').then((m) => {
    console.log(JSON.stringify({has: typeof m.isImageLine === 'function'}));
}).catch(e => { console.log(JSON.stringify({err: String(e && e.message || e)})); });
" 2>&1)
echo "  $RES1"
P1=0
echo "$RES1" | grep -q '"has":false' && P1=1
emit $P1 0.09 "isImageLine no longer exported from terminal-image.ts"

# ---------- F2P #2 (0.06): tui.ts no longer imports isImageLine ----------
echo ""
echo "=== F2P 2 (0.06): tui.ts does not import isImageLine ==="
P2=1
grep -qE 'import\s*\{[^}]*\bisImageLine\b[^}]*\}\s*from\s*["'\''][^"'\'']*terminal-image' "$TUI_FILE" && P2=0
emit $P2 0.06 "tui.ts does not import isImageLine"

# ---------- F2P #3 (0.06): markdown.ts no longer imports isImageLine ----------
echo ""
echo "=== F2P 3 (0.06): markdown.ts does not import isImageLine ==="
P3=1
grep -qE 'import\s*\{[^}]*\bisImageLine\b[^}]*\}\s*from\s*["'\''][^"'\'']*terminal-image' "$MD_FILE" && P3=0
emit $P3 0.06 "markdown.ts does not import isImageLine"

# ---------- F2P #4 (0.15): tui.ts has containsImage method that BEHAVIORALLY
# detects both kitty and iterm2 sequences via includes(), independent of
# any capability/getCapabilities call. Build a tiny harness that calls
# the method on real strings.
# ----------
echo ""
echo "=== F2P 4 (0.15): containsImage behavior on synthetic inputs ==="
P4=0
HARNESS=$(cat <<'EOF'
import { TUI } from './packages/tui/src/tui.ts';
const t = new TUI();
// containsImage is private; access dynamically
const fn = (t as any).containsImage?.bind(t);
if (typeof fn !== 'function') {
    console.log(JSON.stringify({err:'containsImage missing'}));
    process.exit(0);
}
const KITTY = "\x1b_Gf=32,t=d,a=T;AAAA\x1b\\";
const ITERM = "\x1b]1337;File=size=10:AAAA\x07";
const KITTY_INDENT = "    \x1b_Gf=32,t=d,a=T;AAAA\x1b\\";
const ITERM_INDENT = "  \x1b]1337;File=inline=1:AAAA\x07";
const MULTIROW = "\x1b[1A\x1b_Gf=32,t=d;data\x1b\\";
const PLAIN = "hello world";
const FAKE = "/path/to/File_1337/foo.png";
const out = {
    kitty: fn(KITTY),
    iterm: fn(ITERM),
    kittyIndent: fn(KITTY_INDENT),
    itermIndent: fn(ITERM_INDENT),
    multirow: fn(MULTIROW),
    plain: fn(PLAIN),
    fake: fn(FAKE),
};
console.log(JSON.stringify(out));
EOF
)
echo "$HARNESS" > /tmp/harness4.ts
RES4=$(node --import tsx /tmp/harness4.ts 2>&1)
echo "  $RES4"
# Required: kitty=true, iterm=true, kittyIndent=true, itermIndent=true,
# multirow=true, plain=false, fake=false.
if echo "$RES4" | grep -q '"kitty":true' \
   && echo "$RES4" | grep -q '"iterm":true' \
   && echo "$RES4" | grep -q '"kittyIndent":true' \
   && echo "$RES4" | grep -q '"itermIndent":true' \
   && echo "$RES4" | grep -q '"multirow":true' \
   && echo "$RES4" | grep -q '"plain":false' \
   && echo "$RES4" | grep -q '"fake":false'; then
    P4=1
fi
emit $P4 0.15 "containsImage detects single-row, multi-row, indented; rejects plain/fake"

# ---------- F2P #5 (0.09): Detection is NOT capability-gated.
# The buggy isImageLine in terminal-image.ts called getImageEscapePrefix()
# which depended on getCapabilities(). The fix puts the detection back in
# tui.ts as a pure string check. Verify by reading the tui.ts source and
# confirming containsImage's body does NOT reference getCapabilities or
# getImageEscapePrefix, AND the file uses includes() against the literal
# escape sequences.
# ----------
echo ""
echo "=== F2P 5 (0.09): containsImage is pure string check (not capability-gated) ==="
P5=0
PURITY=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$TUI_FILE', 'utf8');
// Find the containsImage method body.
const re = /containsImage\s*\([^)]*\)\s*:\s*boolean\s*\{([\s\S]*?)\n\t\}/;
const m = src.match(re);
if (!m) { console.log(JSON.stringify({found:false})); process.exit(0); }
const body = m[1];
const callsCaps = /getCapabilities|getImageEscapePrefix/.test(body);
const usesIncludes = /\.includes\s*\(/.test(body);
const hasKitty = body.indexOf('\u001b_G') >= 0;
const hasIterm = body.indexOf('\u001b]1337;File=') >= 0;
console.log(JSON.stringify({found:true, callsCaps, usesIncludes, hasKitty, hasIterm}));
" 2>&1)
echo "  $PURITY"
if echo "$PURITY" | grep -q '"found":true' \
   && echo "$PURITY" | grep -q '"callsCaps":false' \
   && echo "$PURITY" | grep -q '"usesIncludes":true' \
   && echo "$PURITY" | grep -q '"hasKitty":true' \
   && echo "$PURITY" | grep -q '"hasIterm":true'; then
    P5=1
fi
emit $P5 0.09 "containsImage body is pure string check using includes(), no capability gating"

# ---------- F2P #6 (0.09): Box cache reverted to explicit fields
# (cachedWidth / cachedChildLines / cachedBgSample / cachedLines) AND
# does NOT use a single RenderCache object. This catches "didn't revert
# the box.ts changes from #1084".
# ----------
echo ""
echo "=== F2P 6 (0.09): Box cache reverted to explicit fields ==="
P6=0
BOXCHECK=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('$BOX_FILE', 'utf8');
const hasCachedWidth = /private\s+cachedWidth\??\s*:/.test(src);
const hasCachedChildLines = /private\s+cachedChildLines\??\s*:/.test(src);
const hasCachedBgSample = /private\s+cachedBgSample\??\s*:/.test(src);
const hasCachedLines = /private\s+cachedLines\??\s*:/.test(src);
const hasRenderCacheType = /type\s+RenderCache\b/.test(src);
const hasSingleCacheField = /private\s+cache\?\s*:\s*RenderCache/.test(src);
const usesJoinKey = /childLines\.join\s*\(\s*[\"'\`]\\\\n[\"'\`]\s*\)/.test(src);
console.log(JSON.stringify({hasCachedWidth, hasCachedChildLines, hasCachedBgSample, hasCachedLines, hasRenderCacheType, hasSingleCacheField, usesJoinKey}));
" 2>&1)
echo "  $BOXCHECK"
if echo "$BOXCHECK" | grep -q '"hasCachedWidth":true' \
   && echo "$BOXCHECK" | grep -q '"hasCachedChildLines":true' \
   && echo "$BOXCHECK" | grep -q '"hasCachedBgSample":true' \
   && echo "$BOXCHECK" | grep -q '"hasCachedLines":true' \
   && echo "$BOXCHECK" | grep -q '"hasRenderCacheType":false' \
   && echo "$BOXCHECK" | grep -q '"hasSingleCacheField":false'; then
    P6=1
fi
emit $P6 0.09 "Box uses explicit cached* fields, no RenderCache type"

# ---------- F2P #7 (0.06): markdown.ts no longer special-cases isImageLine
# in its wrap loop. The reverted code wraps unconditionally; the buggy
# code branched on isImageLine. ----------
echo ""
echo "=== F2P 7 (0.06): markdown.ts wraps lines unconditionally ==="
P7=1
# If markdown.ts still has any reference to isImageLine, fail.
grep -qE '\bisImageLine\b' "$MD_FILE" && P7=0
emit $P7 0.06 "markdown.ts has no remaining references to isImageLine"

# ============================================================
# Final reward (existing gates)
# ============================================================
echo ""
echo "EARNED=$EARNED / TOTAL=$TOTAL"
REWARD=$(awk -v e="$EARNED" -v t="$TOTAL" 'BEGIN{ if (t<=0) {print "0.0000"} else {r=e/t; if (r<0) r=0; if (r>1) r=1; printf "%.4f", r}}')
echo "REWARD=$REWARD"
echo "$REWARD" > "$REWARD_FILE"

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier
GATES_FILE="/logs/verifier/gates.json"
> "$GATES_FILE"

emit_gate() {
    local id=$1 passed=$2 detail=$3
    echo "{\"id\": \"$id\", \"passed\": $passed, \"detail\": \"$detail\"}" >> "$GATES_FILE"
}

# F2P upstream gate 1: isImageLine export removed from terminal-image
echo ""
echo "=== Upstream F2P: isImageLine removed from terminal-image module ==="
UPSTREAM_F2P1_OUT=$(cd /workspace/pi-mono && node --import tsx -e "import('./packages/tui/src/terminal-image.js').then(m => { if (typeof m.isImageLine === 'function') { console.error('FAIL: isImageLine still exported'); process.exit(1); } console.log('PASS'); })" 2>&1)
UPSTREAM_F2P1_RC=$?
echo "  RC=$UPSTREAM_F2P1_RC $UPSTREAM_F2P1_OUT"
if [ "$UPSTREAM_F2P1_RC" -eq 0 ]; then
    emit_gate "f2p_upstream_isImageLine_removed" "true" "isImageLine no longer exported"
else
    emit_gate "f2p_upstream_isImageLine_removed" "false" "isImageLine still exported"
fi

# F2P upstream gate 2: containsImage method exists in TUI class
echo ""
echo "=== Upstream F2P: containsImage exists in TUI prototype ==="
UPSTREAM_F2P2_OUT=$(cd /workspace/pi-mono && node --import tsx -e "import('./packages/tui/src/tui.js').then(m => { const proto = m.TUI.prototype; if (typeof proto.containsImage !== 'function') { console.error('FAIL: containsImage missing from TUI'); process.exit(1); } console.log('PASS'); })" 2>&1)
UPSTREAM_F2P2_RC=$?
echo "  RC=$UPSTREAM_F2P2_RC $UPSTREAM_F2P2_OUT"
if [ "$UPSTREAM_F2P2_RC" -eq 0 ]; then
    emit_gate "f2p_upstream_containsImage_exists" "true" "containsImage found in TUI"
else
    emit_gate "f2p_upstream_containsImage_exists" "false" "containsImage missing from TUI"
fi

# P2P upstream gate 1: TUI package builds
echo ""
echo "=== Upstream P2P: TUI package build ==="
UPSTREAM_P2P1_OUT=$(cd /workspace/pi-mono/packages/tui && npm run build 2>&1)
UPSTREAM_P2P1_RC=$?
echo "  RC=$UPSTREAM_P2P1_RC"
if [ "$UPSTREAM_P2P1_RC" -eq 0 ]; then
    emit_gate "p2p_upstream_tui_build" "true" "TUI build succeeded"
else
    emit_gate "p2p_upstream_tui_build" "false" "TUI build failed"
fi

# P2P upstream gate 2: terminal-image tests pass
echo ""
echo "=== Upstream P2P: terminal-image tests ==="
UPSTREAM_P2P2_OUT=$(cd /workspace/pi-mono && node --test --import tsx packages/tui/test/terminal-image.test.ts 2>&1)
UPSTREAM_P2P2_RC=$?
echo "  RC=$UPSTREAM_P2P2_RC"
if [ "$UPSTREAM_P2P2_RC" -eq 0 ]; then
    emit_gate "p2p_upstream_terminal_image_tests" "true" "terminal-image tests passed"
else
    emit_gate "p2p_upstream_terminal_image_tests" "false" "terminal-image tests failed"
fi

# P2P upstream gate 3: markdown tests pass
echo ""
echo "=== Upstream P2P: markdown tests ==="
UPSTREAM_P2P3_OUT=$(cd /workspace/pi-mono && node --test --import tsx packages/tui/test/markdown.test.ts 2>&1)
UPSTREAM_P2P3_RC=$?
echo "  RC=$UPSTREAM_P2P3_RC"
if [ "$UPSTREAM_P2P3_RC" -eq 0 ]; then
    emit_gate "p2p_upstream_markdown_tests" "true" "markdown tests passed"
else
    emit_gate "p2p_upstream_markdown_tests" "false" "markdown tests failed"
fi

# ---- end upstream gates ----

# ---- upstream reward tail ----
python3 - <<'PYEOF'
import json, os, sys
WEIGHTS = {
    "f2p_isImageLine_export_removed": 0.09,
    "f2p_tui_no_import_isImageLine": 0.06,
    "f2p_markdown_no_import_isImageLine": 0.06,
    "f2p_containsImage_behavior": 0.15,
    "f2p_containsImage_pure_check": 0.09,
    "f2p_box_cache_reverted": 0.09,
    "f2p_markdown_wraps_unconditionally": 0.06,
    "f2p_upstream_isImageLine_removed": 0.2,
    "f2p_upstream_containsImage_exists": 0.2
}
P2P_REGRESSION = ["p2p_no_merge_conflicts", "p2p_tui_parses", "p2p_terminal_image_parses", "p2p_markdown_parses", "p2p_box_parses", "p2p_upstream_tui_build", "p2p_upstream_terminal_image_tests", "p2p_upstream_markdown_tests"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            d = json.loads(line)
            gid = d.get('id')
            if gid:
                verdicts[gid] = bool(d.get('passed'))
except FileNotFoundError:
    pass
existing = 0.0
try:
    with open('/logs/verifier/reward.txt') as f:
        existing = float(f.read().strip() or 0)
except Exception:
    pass

# P2P_REGRESSION_INFORMATIONAL: P2P_REGRESSION items are now informational only.
# Pre-existing TS/test errors unrelated to model task scope must not zero reward.
p2p_reg_failed = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)  # logged below
p2p_failed = False  # was: any(... in P2P_REGRESSION) — dropped per v043 fix
f2p_any_pass = any(verdicts.get(gid, False) for gid in WEIGHTS) if WEIGHTS else True
if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    # Weighted-replace: upstream F2P gate weights replace a proportional
    # share of the bash-computed inner reward. When WEIGHTS sums to 1.0, the
    # inner reward is fully subsumed by upstream gates (intentional). When
    # WEIGHTS sums to <1.0, the remainder scales the legacy inner reward so
    # the total is naturally bounded to [0, 1] without additive inflation.
    inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
    reward = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
reward = max(0.0, min(1.0, reward))
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write(f"{reward:.4f}\n")
PYEOF
# ---- end ----
exit 0