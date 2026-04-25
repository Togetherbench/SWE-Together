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

# ============================================================
# P2P GATE (gating, no reward): TypeScript must still compile.
# If the agent broke compilation, score 0 and exit.
# ============================================================
echo "============================================================"
echo "P2P Gate: TypeScript compile check (gating, no reward)"
echo "============================================================"
TSC_OUT=$(npx --no-install tsc --noEmit 2>&1)
TSC_EXIT=$?
echo "$TSC_OUT" | tail -30
if [ $TSC_EXIT -ne 0 ]; then
    echo "TSC: FAIL — regression, score 0"
    echo "0.0000" > /logs/verifier/reward.txt
    exit 0
fi
echo "TSC: PASS"

# ============================================================
# Helper: read file or empty
# ============================================================
RADIX_PROPS=("onOpenAutoFocus" "onPointerDownOutside" "onInteractOutside")

# Strip line/block comments from file contents (for prop-usage scanning).
strip_comments() {
    # $1 = path
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

# Check whether a file contains an active JSX attribute usage like `prop={` or `prop="`
file_uses_prop_attr() {
    # $1 = path, $2 = prop name
    local content
    content=$(strip_comments "$1")
    echo "$content" | grep -E "\\b$2[[:space:]]*=[[:space:]]*[\\{\"]" >/dev/null 2>&1
}

# ============================================================
# F2P Gate 1 (weight 0.20):
# DatasetBrowserModal must no longer pass onOpenAutoFocus to
# DialogContent (this is the prop named in the original error).
# Buggy base: passes onOpenAutoFocus={...} → fails.
# ============================================================
echo ""
echo "============================================================"
echo "F2P Gate 1 (0.20): DatasetBrowserModal no longer leaks onOpenAutoFocus"
echo "============================================================"
G1_FILE="src/shared/components/DatasetBrowserModal.tsx"
if [ -f "$G1_FILE" ]; then
    if file_uses_prop_attr "$G1_FILE" "onOpenAutoFocus"; then
        echo "FAIL: $G1_FILE still has onOpenAutoFocus={...}"
    else
        echo "PASS"
        add 0.20
    fi
else
    echo "SKIP: file missing"
fi

# ============================================================
# F2P Gate 2 (weight 0.25):
# VideoGenerationModal must remove the dead Radix handlers
# (onPointerDownOutside / onInteractOutside / onOpenAutoFocus
# as JSX attributes on DialogContent).
# Buggy base passes all three → fails.
# ============================================================
echo ""
echo "============================================================"
echo "F2P Gate 2 (0.25): VideoGenerationModal cleans dead Radix handlers"
echo "============================================================"
G2_FILE="src/tools/travel-between-images/components/VideoGenerationModal.tsx"
if [ -f "$G2_FILE" ]; then
    leaks=0
    for p in onPointerDownOutside onInteractOutside onOpenAutoFocus; do
        if file_uses_prop_attr "$G2_FILE" "$p"; then
            echo "  still leaks: $p"
            leaks=$((leaks+1))
        fi
    done
    if [ $leaks -eq 0 ]; then
        echo "PASS"
        add 0.25
    else
        echo "FAIL: $leaks dead handlers remain"
    fi
else
    echo "SKIP: file missing"
fi

# ============================================================
# F2P Gate 3 (weight 0.20):
# VideoGenerationModal must preserve the isLoraModalOpen guard
# on close (regression guard for behavior). The original
# guard lived in onPointerDownOutside/onInteractOutside —
# after removing those, the guard must move to onOpenChange or
# a named close handler. Buggy base does NOT pass this gate when
# combined with Gate 2: on base, gate 2 fails so this gate does
# not award; we additionally require that AFTER cleanup, the
# guard exists in onOpenChange / handler. This makes the gate
# F2P: passes only when handlers are removed AND guard is lifted.
# ============================================================
echo ""
echo "============================================================"
echo "F2P Gate 3 (0.20): isLoraModalOpen guard lifted to onOpenChange"
echo "============================================================"
if [ -f "$G2_FILE" ]; then
    # Must have removed the dead handler attributes (otherwise the
    # base file already has isLoraModalOpen mentioned, so we'd
    # falsely award).
    base_leaks=0
    for p in onPointerDownOutside onInteractOutside; do
        if file_uses_prop_attr "$G2_FILE" "$p"; then
            base_leaks=$((base_leaks+1))
        fi
    done

    if [ $base_leaks -gt 0 ]; then
        echo "FAIL: dead outside-handlers still present, can't award guard-lift"
    else
        # Now require guard reference inside onOpenChange={...}
        # or inside a named close/openChange handler.
        node -e '
const fs=require("fs");
const src=fs.readFileSync(process.argv[1],"utf8")
  .replace(/\/\*[\s\S]*?\*\//g,"")
  .split("\n").filter(l=>!l.trim().startsWith("//")).join("\n");
const oneLine=src.replace(/\s+/g," ");
// onOpenChange={ ... isLoraModalOpen ... }
const re1=/onOpenChange\s*=\s*\{[^}]*isLoraModalOpen[^}]*\}/;
// any handler def referencing isLoraModalOpen and onClose
const re2=/(handle\w*|on\w*)\s*=\s*[^=][^;]{0,400}isLoraModalOpen/;
if (re1.test(oneLine) || re2.test(oneLine)) {
  console.log("PASS");
  process.exit(0);
}
console.log("FAIL: no guard found in onOpenChange or handler");
process.exit(1);
' "$G2_FILE"
        if [ $? -eq 0 ]; then
            add 0.20
        fi
    fi
else
    echo "SKIP: file missing"
fi

# ============================================================
# F2P Gate 4 (weight 0.20):
# useModal hook no longer plants onOpenAutoFocus into the props
# it returns. Buggy base sets it for mobile → fails.
# Accept either:
#   - onOpenAutoFocus is no longer referenced in real code
#   - the file has been removed/restructured (TSC already passed)
# ============================================================
echo ""
echo "============================================================"
echo "F2P Gate 4 (0.20): useModal cleaned of onOpenAutoFocus"
echo "============================================================"
G4_FILE="src/shared/hooks/useModal.ts"
if [ ! -f "$G4_FILE" ]; then
    # File restructured/removed and TSC passed → accept
    echo "PASS (file moved/removed, TSC green)"
    add 0.20
else
    node -e '
const fs=require("fs");
const raw=fs.readFileSync(process.argv[1],"utf8");
// Strip comments and string literals so we only see real code
const stripped=raw
  .replace(/\/\*[\s\S]*?\*\//g,"")
  .split("\n").filter(l=>!l.trim().startsWith("//")).join("\n")
  .replace(/"(?:[^"\\]|\\.)*"/g,"\"\"")
  .replace(/`(?:[^`\\]|\\.)*`/g,"``")
  .replace(/'"'"'(?:[^'"'"'\\]|\\.)*'"'"'/g,"''");
if (/\bonOpenAutoFocus\b/.test(stripped)) {
  console.log("FAIL: useModal still references onOpenAutoFocus");
  process.exit(1);
}
console.log("PASS");
process.exit(0);
' "$G4_FILE"
    if [ $? -eq 0 ]; then
        add 0.20
    fi
fi

# ============================================================
# F2P Gate 5 (weight 0.15):
# At least one OTHER caller (ImageGenerationModal, ai-input-button,
# or PromptEditorModal) has dropped the dead Radix attributes from
# its DialogContent/PopoverContent JSX. Buggy base has all three
# leaking → fails until at least one is cleaned.
# ============================================================
echo ""
echo "============================================================"
echo "F2P Gate 5 (0.15): at least one additional caller cleaned"
echo "============================================================"
OTHER_CALLERS=(
  "src/shared/components/ImageGenerationModal.tsx"
  "src/shared/components/ui/ai-input-button.tsx"
  "src/shared/components/PromptEditorModal.tsx"
)

cleaned=0
present=0
for f in "${OTHER_CALLERS[@]}"; do
    [ -f "$f" ] || continue
    present=$((present+1))
    # On the buggy base, each of these has at least onOpenAutoFocus={
    # or onPointerDownOutside={ as a JSX attribute.
    leaks=0
    for p in onOpenAutoFocus onPointerDownOutside onInteractOutside; do
        if file_uses_prop_attr "$f" "$p"; then
            leaks=$((leaks+1))
        fi
    done
    if [ $leaks -eq 0 ]; then
        echo "  cleaned: $f"
        cleaned=$((cleaned+1))
    else
        echo "  still leaks ($leaks): $f"
    fi
done

if [ $present -gt 0 ] && [ $cleaned -ge 1 ]; then
    echo "PASS"
    add 0.15
else
    echo "FAIL"
fi

echo ""
echo "============================================================"
echo "FINAL REWARD: $REWARD"
echo "============================================================"
echo "$REWARD" > /logs/verifier/reward.txt