#!/bin/bash
set +e

REPO="/workspace/repo"
if [ ! -d "$REPO" ]; then
    for d in /workspace/*/; do
        if [ -f "$d/package.json" ]; then REPO="${d%/}"; break; fi
    done
fi

mkdir -p /logs/verifier
cd "$REPO" || { echo "0.0000" > /logs/verifier/reward.txt; exit 0; }

export PATH="$PATH:/usr/local/bin:/usr/bin:/root/.npm-global/bin:/root/.bun/bin"

REWARD=0
add() {
    REWARD=$(awk "BEGIN {printf \"%.4f\", $REWARD + $1}")
}

# ---------- Helpers ----------
strip_comments() {
    [ -f "$1" ] || { echo ""; return; }
    node -e '
const fs=require("fs");
try {
  let s=fs.readFileSync(process.argv[1],"utf8");
  s=s.replace(/\/\*[\s\S]*?\*\//g,"");
  s=s.split("\n").filter(l=>!l.trim().startsWith("//")).join("\n");
  process.stdout.write(s);
} catch(e){}
' "$1"
}

file_uses_prop_attr() {
    local content
    content=$(strip_comments "$1")
    echo "$content" | grep -E "\b$2[[:space:]]*=[[:space:]]*[\{\"]" >/dev/null 2>&1
}

# ============================================================
# P2P Gate (gating only): TypeScript compile must pass
# ============================================================
echo "============================================================"
echo "P2P Gate: TypeScript compile (gating)"
echo "============================================================"
if ! command -v npx >/dev/null 2>&1; then
    echo "npx missing"
    echo "0.0000" > /logs/verifier/reward.txt
    exit 0
fi
TSC_OUT=$(timeout 240 npx --no-install tsc --noEmit 2>&1)
TSC_EXIT=$?
echo "$TSC_OUT" | tail -20
if [ $TSC_EXIT -ne 0 ]; then
    echo "TSC: FAIL — regression, score 0"
    echo "0.0000" > /logs/verifier/reward.txt
    exit 0
fi
echo "TSC: PASS"

# Also reject any merge conflict markers (one of the captured patches left some)
if grep -RIn -E "^(<<<<<<<|=======|>>>>>>>) " src 2>/dev/null | head -1 | grep -q .; then
    echo "Merge conflict markers found in src/. Score 0."
    echo "0.0000" > /logs/verifier/reward.txt
    exit 0
fi

# ============================================================
# Gate 1 (0.18): DatasetBrowserModal no longer passes onOpenAutoFocus
# This is the file in the original error stack.
# ============================================================
echo ""
echo "============================================================"
echo "Gate 1 (0.18): DatasetBrowserModal removes onOpenAutoFocus"
echo "============================================================"
G1="src/shared/components/DatasetBrowserModal.tsx"
if [ -f "$G1" ]; then
    if file_uses_prop_attr "$G1" "onOpenAutoFocus"; then
        echo "FAIL: still uses onOpenAutoFocus"
    else
        echo "PASS"
        add 0.18
    fi
else
    echo "SKIP: missing"
fi

# ============================================================
# Gate 2 (0.18): VideoGenerationModal removes the dead Radix handlers
# (onPointerDownOutside, onInteractOutside, onOpenAutoFocus)
# ============================================================
echo ""
echo "============================================================"
echo "Gate 2 (0.18): VideoGenerationModal cleans dead handlers"
echo "============================================================"
G2="src/tools/travel-between-images/components/VideoGenerationModal.tsx"
if [ -f "$G2" ]; then
    leaks=0
    for p in onPointerDownOutside onInteractOutside onOpenAutoFocus; do
        if file_uses_prop_attr "$G2" "$p"; then
            echo "  leaks: $p"
            leaks=$((leaks+1))
        fi
    done
    if [ $leaks -eq 0 ]; then
        echo "PASS"
        add 0.18
    else
        echo "FAIL: $leaks leaks"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 3 (0.14): VideoGenerationModal preserves isLoraModalOpen guard
# After removing the outside handlers, the close behavior must still
# respect isLoraModalOpen (lifted to onOpenChange or a handler).
# ============================================================
echo ""
echo "============================================================"
echo "Gate 3 (0.14): isLoraModalOpen guard preserved on close"
echo "============================================================"
if [ -f "$G2" ]; then
    base_leaks=0
    for p in onPointerDownOutside onInteractOutside; do
        if file_uses_prop_attr "$G2" "$p"; then
            base_leaks=$((base_leaks+1))
        fi
    done
    if [ $base_leaks -gt 0 ]; then
        echo "FAIL: outside handlers still present, can't credit guard-lift"
    else
        node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8")
  .replace(/\/\*[\s\S]*?\*\//g,"")
  .split("\n").filter(l=>!l.trim().startsWith("//")).join("\n");
const oneLine=src.replace(/\s+/g," ");
const re1=/onOpenChange\s*=\s*\{[^}]*isLoraModalOpen[^}]*\}/;
const re2=/(handle\w*|on\w*)\s*=\s*[^=][^;]{0,400}isLoraModalOpen/;
if (re1.test(oneLine) || re2.test(oneLine)) { console.log("PASS"); process.exit(0); }
console.log("FAIL: no guard"); process.exit(1);
' "$G2"
        if [ $? -eq 0 ]; then
            add 0.14
        fi
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 4 (0.14): useModal hook no longer plants onOpenAutoFocus
# in the props it returns. This is the source of the "modal.props"
# spread that contaminates Dialog receivers.
# ============================================================
echo ""
echo "============================================================"
echo "Gate 4 (0.14): useModal returned props don't contain onOpenAutoFocus"
echo "============================================================"
G4="src/shared/hooks/useModal.ts"
if [ ! -f "$G4" ]; then
    echo "PASS (file restructured, tsc passed)"
    add 0.14
else
    content=$(strip_comments "$G4")
    if echo "$content" | grep -E "onOpenAutoFocus" >/dev/null 2>&1; then
        echo "FAIL: useModal still references onOpenAutoFocus"
    else
        echo "PASS"
        add 0.14
    fi
fi

# ============================================================
# Gate 5 (0.18): play() AbortError fix — at least 4 of the
# play() callsites must defend against unhandled promise rejections
# (either via .catch(...) or via await + try/catch in surrounding code).
# This is the second error from the instructions: "AbortError: The
# play() request was interrupted by a call to pause()".
# ============================================================
echo ""
echo "============================================================"
echo "Gate 5 (0.18): play() callsites defended against AbortError"
echo "============================================================"
TARGETS=(
    "src/pages/Home/components/panes/sections/MotionReferenceSection.tsx"
    "src/shared/components/TaskDetails/components/TaskDetailsLazyVideoPreview.tsx"
    "src/shared/components/StyledVideoPlayer/hooks/useVideoPlayerControls.ts"
    "src/shared/components/VideoPortionTimeline/hooks/useHandleDrag.ts"
    "src/shared/components/VideoPortionTimeline/hooks/usePlayhead.ts"
    "src/tools/travel-between-images/components/Timeline/AudioStrip.tsx"
)
defended=0
total_present=0
for f in "${TARGETS[@]}"; do
    if [ -f "$f" ]; then
        total_present=$((total_present+1))
        # Count play() calls
        play_count=$(grep -cE "\.play\(\)" "$f" 2>/dev/null)
        # Count play().catch( or AbortError handling
        guarded=$(grep -cE "\.play\(\)\.catch\(|\.play\(\)\s*;?\s*//.*Abort" "$f" 2>/dev/null)
        if [ "$play_count" -gt 0 ] && [ "$guarded" -gt 0 ]; then
            defended=$((defended+1))
        elif [ "$play_count" -eq 0 ]; then
            # play() removed entirely (refactored) — accept
            defended=$((defended+1))
        fi
    fi
done
echo "  defended=$defended / present=$total_present"
if [ $total_present -gt 0 ]; then
    # Award proportionally: full only if >=4 defended
    if [ $defended -ge 4 ]; then
        echo "PASS (full)"
        add 0.18
    elif [ $defended -ge 2 ]; then
        echo "PARTIAL"
        add 0.09
    else
        echo "FAIL"
    fi
else
    echo "SKIP"
fi

# ============================================================
# Gate 6 (0.10): safePlay handles AbortError specifically — does
# not report it as a recoverable error. Behavioral check via runtime.
# ============================================================
echo ""
echo "============================================================"
echo "Gate 6 (0.10): safePlay swallows AbortError without reporting"
echo "============================================================"
G6="src/shared/lib/media/safePlay.ts"
if [ -f "$G6" ]; then
    content=$(strip_comments "$G6")
    # Must reference AbortError name OR isAbortError import
    if echo "$content" | grep -E "AbortError|isAbortError" >/dev/null 2>&1; then
        echo "PASS (AbortError-aware)"
        add 0.10
    else
        echo "FAIL: no AbortError handling"
    fi
else
    echo "SKIP: file missing"
fi

# ============================================================
# Gate 7 (0.08): Completeness — at least 3 of these "shape changes"
# present. Encourages broader cleanup vs. surface-only fix.
# ============================================================
echo ""
echo "============================================================"
echo "Gate 7 (0.08): Completeness — multiple call-sites cleaned"
echo "============================================================"
shape=0

# 7a: ImageGenerationModal cleaned
F7A="src/shared/components/ImageGenerationModal.tsx"
if [ -f "$F7A" ]; then
    leaks7a=0
    for p in onOpenAutoFocus onPointerDownOutside onInteractOutside; do
        if file_uses_prop_attr "$F7A" "$p"; then
            leaks7a=$((leaks7a+1))
        fi
    done
    if [ $leaks7a -eq 0 ]; then shape=$((shape+1)); echo "  ImageGenerationModal: clean"; fi
fi

# 7b: PromptEditorModal cleaned of dead onInteractOutside / onPointerDownOutside
F7B="src/shared/components/PromptEditorModal.tsx"
if [ -f "$F7B" ]; then
    leaks7b=0
    for p in onPointerDownOutside onInteractOutside; do
        if file_uses_prop_attr "$F7B" "$p"; then
            leaks7b=$((leaks7b+1))
        fi
    done
    if [ $leaks7b -eq 0 ]; then shape=$((shape+1)); echo "  PromptEditorModal: clean"; fi
fi

# 7c: ai-input-button cleaned (PopoverContent)
F7C="src/shared/components/ui/ai-input-button.tsx"
if [ -f "$F7C" ]; then
    leaks7c=0
    for p in onOpenAutoFocus onPointerDownOutside onInteractOutside; do
        if file_uses_prop_attr "$F7C" "$p"; then
            leaks7c=$((leaks7c+1))
        fi
    done
    if [ $leaks7c -eq 0 ]; then shape=$((shape+1)); echo "  ai-input-button: clean"; fi
fi

# 7d: Repo-wide check — count remaining "dead" Radix handler attributes in src/
remaining=$(grep -rE --include="*.tsx" --include="*.ts" \
    "(onOpenAutoFocus|onPointerDownOutside|onInteractOutside)[[:space:]]*=" src 2>/dev/null \
    | grep -vE "://|interface |type |^\s*//|^\s*\*" \
    | grep -vE "\.d\.ts:" \
    | wc -l)
echo "  remaining dead-handler attribute usages in src: $remaining"
if [ "$remaining" -le 1 ]; then shape=$((shape+1)); echo "  repo-wide cleanup: good"; fi

echo "  shape score=$shape"
if [ $shape -ge 3 ]; then
    echo "PASS"
    add 0.08
elif [ $shape -ge 2 ]; then
    echo "PARTIAL"
    add 0.04
else
    echo "FAIL"
fi

# ============================================================
# Final (existing gates)
# ============================================================
echo ""
echo "============================================================"
echo "EXISTING GATES REWARD: $REWARD"
echo "============================================================"
echo "$REWARD" > /logs/verifier/reward.txt

# ---- inner-claude upstream gates ----
mkdir -p /logs/verifier

echo ""
echo "============================================================"
echo "Upstream F2P Gate: useModal props field removed"
echo "============================================================"
if ! grep -qE 'props:\s*(Record|mobileProps)' src/shared/hooks/useModal.ts 2>/dev/null; then
    echo "PASS: useModal no longer returns props field"
    echo '{"id": "f2p_upstream_usemodal_props_removed", "passed": true, "detail": "useModal.ts does not contain props field"}' >> /logs/verifier/gates.json
else
    echo "FAIL: useModal still has props field"
    echo '{"id": "f2p_upstream_usemodal_props_removed", "passed": false, "detail": "useModal.ts still contains props field"}' >> /logs/verifier/gates.json
fi

echo ""
echo "============================================================"
echo "Upstream F2P Gate: modal.props spread removed from components"
echo "============================================================"
if ! grep -rlqE 'modal\.props' src/shared/components/ src/tools/ --include='*.tsx' 2>/dev/null; then
    echo "PASS: No component spreads modal.props"
    echo '{"id": "f2p_upstream_modal_props_spread_removed", "passed": true, "detail": "No component files reference modal.props"}' >> /logs/verifier/gates.json
else
    echo "FAIL: Components still spread modal.props"
    echo '{"id": "f2p_upstream_modal_props_spread_removed", "passed": false, "detail": "Some component files still reference modal.props"}' >> /logs/verifier/gates.json
fi

echo ""
echo "============================================================"
echo "Upstream P2P Gate: TypeScript compilation"
echo "============================================================"
TSC_GATE_OUT=$(timeout 240 npx --no-install tsc --noEmit 2>&1)
TSC_GATE_EXIT=$?
if [ $TSC_GATE_EXIT -eq 0 ]; then
    echo "PASS: TSC compile succeeds"
    echo '{"id": "p2p_upstream_tsc_compile", "passed": true, "detail": "tsc --noEmit passed"}' >> /logs/verifier/gates.json
else
    echo "FAIL: TSC compile failed"
    echo "$TSC_GATE_OUT" | tail -10
    echo '{"id": "p2p_upstream_tsc_compile", "passed": false, "detail": "tsc --noEmit failed"}' >> /logs/verifier/gates.json
fi

# ---- upstream reward adjustment ----
python3 - << 'PYEOF'
import json, os, sys
WEIGHTS = {"f2p_upstream_usemodal_props_removed": 0.20, "f2p_upstream_modal_props_spread_removed": 0.20}
P2P_REGRESSION = ["p2p_upstream_tsc_compile"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
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
hard_zero = any(not verdicts.get(gid, False) for gid in P2P_REGRESSION)
if hard_zero:
    reward = 0.0
else:
    reward = existing
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += w
    reward = min(reward, 1.0)
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('UPSTREAM REWARD=%.4f (existing=%.4f)' % (reward, existing))
PYEOF
# ---- end ----

echo ""
echo "============================================================"
FINAL_REWARD=$(cat /logs/verifier/reward.txt 2>/dev/null || echo "0.0000")
echo "FINAL REWARD (with upstream gates): $FINAL_REWARD"
echo "============================================================"