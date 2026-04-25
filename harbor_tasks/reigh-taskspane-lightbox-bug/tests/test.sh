#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
echo "0.00" > "$REWARD_FILE"

# Locate workspace
REPO=""
for cand in /workspace/repo /workspace/reigh /workspace/*/; do
  if [ -d "$cand/src/shared/components/TasksPane" ]; then
    REPO="${cand%/}"
    break
  fi
done
if [ -z "$REPO" ]; then
  for d in /workspace/*/; do
    if [ -d "$d/src" ]; then REPO="${d%/}"; break; fi
  done
fi
echo "Using REPO=$REPO"
cd "$REPO" || { echo "0.00" > "$REWARD_FILE"; exit 0; }

export PATH="/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  for p in /root/.nvm/versions/node/*/bin /usr/local/node/bin; do
    [ -d "$p" ] && export PATH="$p:$PATH"
  done
fi

TOTAL=0
add() { TOTAL=$((TOTAL + $1)); awk "BEGIN {printf \"%.2f\", $TOTAL/100}" > "$REWARD_FILE"; }

TASKSPANE="src/shared/components/TasksPane/TasksPane.tsx"
TASKITEM="src/shared/components/TasksPane/TaskItem.tsx"
LIGHTBOX_HOOK="src/shared/components/TasksPane/hooks/useTasksLightbox.ts"
TASK_UTILS="src/shared/components/TasksPane/utils/task-utils.ts"
SOS="src/tools/travel-between-images/components/Timeline/SegmentOutputStrip.tsx"

###############################################################################
# Helper Node script: returns props passed to MediaLightbox in a file.
# Looks at JSX attribute names AND spread-attribute identifiers.
###############################################################################
ML_PROBE='
const ts=require("typescript");
const fs=require("fs");
const path=process.argv[1];
if(!fs.existsSync(path)){console.log("__MISSING__"); process.exit(2);}
const src=fs.readFileSync(path,"utf8");
const sf=ts.createSourceFile("f.tsx",src,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const elems=[];
(function v(n){
  if(ts.isJsxOpeningElement(n)||ts.isJsxSelfClosingElement(n)){
    const tag=n.tagName.getText(sf);
    if(tag==="MediaLightbox"){
      const props=[];
      const spreads=[];
      if(n.attributes&&n.attributes.properties){
        n.attributes.properties.forEach(x=>{
          if(ts.isJsxAttribute(x)&&x.name) props.push(x.name.getText(sf));
          else if(ts.isJsxSpreadAttribute(x)) spreads.push(x.expression.getText(sf));
        });
      }
      elems.push({props,spreads});
    }
  }
  ts.forEachChild(n,v);
})(sf);
console.log(JSON.stringify(elems));
'

probe_ml() {
  node -e "$ML_PROBE" "$1" 2>/dev/null
}

# Returns 0 if any MediaLightbox in TasksPane (or hook chain) provides the prop
# either directly or via a spread of a known props object whose source we'll
# inspect. We do best-effort: check direct attrs and spread var names.
has_ml_prop() {
  local file="$1"
  local prop="$2"
  local data
  data=$(probe_ml "$file")
  if [ -z "$data" ] || [ "$data" = "__MISSING__" ]; then return 1; fi
  node -e "
const elems=JSON.parse(process.argv[1]);
const prop=process.argv[2];
for(const e of elems){
  if(e.props.includes(prop)){console.log('DIRECT'); process.exit(0);}
}
console.log('NONE'); process.exit(1);
" "$data" "$prop" >/dev/null 2>&1
}

# Reference: how SegmentOutputStrip calls MediaLightbox (for shape comparison)
get_sos_props() {
  probe_ml "$SOS"
}

###############################################################################
# Gate A (P2P, 0.10): SegmentOutputStrip still passes shotId — regression guard
###############################################################################
echo "=== Gate A: SegmentOutputStrip regression guard (P2P, 0.10) ==="
GA=0
SOS_DATA=$(get_sos_props)
if echo "$SOS_DATA" | grep -q '"shotId"'; then
  echo "PASS: SegmentOutputStrip still passes shotId"
  GA=10
else
  echo "FAIL: SegmentOutputStrip lost shotId"
fi
add $GA

###############################################################################
# Gate B (P2P, 0.10): task-utils still uses correct task-type key
# (regression: many agents flipped task_type<->taskType; ensure the field used
# matches the Task type definition.)
###############################################################################
echo "=== Gate B: isSegmentVideoTask uses field present on Task type (P2P, 0.10) ==="
GB=0
if [ -f "$TASK_UTILS" ]; then
  # Find the field name actually present on Task type
  TYPE_FILE="src/types/tasks.ts"
  [ ! -f "$TYPE_FILE" ] && TYPE_FILE=$(grep -rl "interface Task " src/types 2>/dev/null | head -1)
  TASK_FIELD=""
  if [ -n "$TYPE_FILE" ] && [ -f "$TYPE_FILE" ]; then
    if grep -qE "taskType\s*[:?]" "$TYPE_FILE"; then TASK_FIELD="taskType"; fi
    if [ -z "$TASK_FIELD" ] && grep -qE "task_type\s*[:?]" "$TYPE_FILE"; then TASK_FIELD="task_type"; fi
  fi
  if [ -z "$TASK_FIELD" ]; then TASK_FIELD="taskType"; fi
  if grep -qE "task\.${TASK_FIELD}\s*===\s*['\"]individual_travel_segment['\"]" "$TASK_UTILS"; then
    echo "PASS: isSegmentVideoTask uses task.$TASK_FIELD"
    GB=10
  else
    echo "FAIL: isSegmentVideoTask doesn't reference task.$TASK_FIELD correctly"
  fi
else
  echo "FAIL: task-utils missing"
fi
add $GB

###############################################################################
# Gate C (F2P, 0.15): TypeScript compilation succeeds (behavioral)
# A real fix integrates new state/props correctly; type errors → broken fix.
###############################################################################
echo "=== Gate C: TypeScript compiles (F2P, 0.15) ==="
GC=0
TSC_OUT=$(mktemp)
if [ -f node_modules/typescript/bin/tsc ]; then
  node node_modules/typescript/bin/tsc --noEmit > "$TSC_OUT" 2>&1
  TSC_EXIT=$?
elif command -v npx >/dev/null 2>&1; then
  npx --no-install tsc --noEmit > "$TSC_OUT" 2>&1
  TSC_EXIT=$?
else
  TSC_EXIT=127
fi
ERR_COUNT=$(grep -cE "error TS[0-9]+" "$TSC_OUT" 2>/dev/null)
[ -z "$ERR_COUNT" ] && ERR_COUNT=0
echo "tsc exit=$TSC_EXIT, error count=$ERR_COUNT"
tail -20 "$TSC_OUT"
if [ "$TSC_EXIT" = "0" ]; then
  GC=15
elif [ "$ERR_COUNT" -le 3 ]; then
  # near-clean: partial credit
  GC=8
elif [ "$ERR_COUNT" -le 10 ]; then
  GC=4
fi
rm -f "$TSC_OUT"
add $GC

###############################################################################
# Gate D (F2P, 0.20): Click handler in TasksPane area routes segment-video
# tasks to shot context (chevron/constituent images come from full context).
# Two acceptable strategies (implementation-agnostic):
#   1) Navigate to /tools/travel-between-images#<shotId> with state carrying
#      a deep-link to the segment slot.
#   2) Open MediaLightbox locally with shot-context props (shotId +
#      segmentSlotMode OR currentSegmentImages + currentFrameCount).
# Either approach must be wired through isSegmentVideoTask and shotId.
###############################################################################
echo "=== Gate D: Segment-video click handler routes to shot context (F2P, 0.20) ==="
GD=0
ROUTING_HITS=0

# Strategy 1: navigation deep-link
if grep -rE "travel-between-images#" src/shared/components/TasksPane src/shared/hooks/segments 2>/dev/null \
    | grep -q "."; then
  if grep -rE "openSegmentSlot|fromShotClick" src/shared/components/TasksPane src/shared/hooks 2>/dev/null \
      | grep -q "."; then
    ROUTING_HITS=$((ROUTING_HITS+1))
    echo "Found: navigation deep-link strategy (openSegmentSlot/fromShotClick)"
  fi
fi

# Strategy 2: in-place lightbox with shot context
if has_ml_prop "$TASKSPANE" "shotId" || has_ml_prop "$TASKSPANE" "segmentSlotMode"; then
  ROUTING_HITS=$((ROUTING_HITS+1))
  echo "Found: in-place lightbox shot-context strategy"
fi

# Confirm the routing is *gated* by isSegmentVideoTask somewhere in TasksPane tree
GATED=0
if grep -rE "isSegmentVideoTask\s*\(" src/shared/components/TasksPane src/shared/hooks 2>/dev/null \
    | grep -v "export const isSegmentVideoTask" | grep -q "."; then
  GATED=1
fi

if [ $ROUTING_HITS -ge 1 ] && [ $GATED -eq 1 ]; then
  GD=20
  echo "PASS: segment-video routing wired (strategies=$ROUTING_HITS, gated=$GATED)"
elif [ $ROUTING_HITS -ge 1 ] || [ $GATED -eq 1 ]; then
  GD=10
  echo "PARTIAL: routing partially wired (strategies=$ROUTING_HITS, gated=$GATED)"
else
  echo "FAIL: no shot-context routing found"
fi
add $GD

###############################################################################
# Gate E (F2P, 0.20): TasksPane's MediaLightbox actually receives shot context
# props that enable chevron/constituent-images functionality.
# Implementation-agnostic: accept either
#   (a) segmentSlotMode prop (single object encapsulating context), OR
#   (b) at least 2 of {shotId, currentSegmentImages, currentFrameCount,
#       showVideoTrimEditor, segmentImages, pairData}
###############################################################################
echo "=== Gate E: TasksPane MediaLightbox receives shot-context props (F2P, 0.20) ==="
GE=0

# Search MediaLightbox usages in TasksPane file *and* in TaskItem and lightbox hook
ML_FILES="$TASKSPANE $TASKITEM $LIGHTBOX_HOOK"
# Also include any segment-slot lightbox hook the agent may have created
EXTRA=$(grep -rl "MediaLightbox" src/shared/components/TasksPane src/shared/hooks/segments 2>/dev/null)
ML_FILES="$ML_FILES $EXTRA"

declare -A SEEN
COUNT=0
HAS_SLOTMODE=0
for f in $ML_FILES; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  [ -n "${SEEN[$f]}" ] && continue
  SEEN[$f]=1
  data=$(probe_ml "$f")
  [ -z "$data" ] && continue
  for prop in segmentSlotMode shotId currentSegmentImages currentFrameCount showVideoTrimEditor segmentImages pairData; do
    if echo "$data" | grep -q "\"$prop\""; then
      if [ "$prop" = "segmentSlotMode" ]; then
        HAS_SLOTMODE=1
      else
        if [ -z "${SEEN_PROP[$prop]}" ]; then
          SEEN_PROP[$prop]=1
          COUNT=$((COUNT+1))
        fi
      fi
    fi
  done
done

echo "shot-context prop count=$COUNT, has segmentSlotMode=$HAS_SLOTMODE"
if [ $HAS_SLOTMODE -eq 1 ] || [ $COUNT -ge 3 ]; then
  GE=20
  echo "PASS: full shot context"
elif [ $COUNT -eq 2 ]; then
  GE=12
  echo "PARTIAL: partial shot context"
elif [ $COUNT -eq 1 ]; then
  GE=5
  echo "WEAK: minimal shot context"
else
  echo "FAIL: no shot-context props on MediaLightbox in TasksPane chain"
fi
add $GE

###############################################################################
# Gate F (F2P, 0.15): Mobile path also routed (parity with desktop)
# A complete fix handles both desktop click and mobile tap. Look for
# isSegmentVideoTask check inside a mobile/tap branch.
###############################################################################
echo "=== Gate F: Mobile tap parity for segment videos (F2P, 0.15) ==="
GF=0
if [ -f "$TASKITEM" ]; then
  # Find a region near "isMobileActive" or "handleMobileTap" or "isMobile" referencing isSegmentVideoTask
  if awk '
    /isMobileActive|handleMobileTap|isMobile/ {region=NR}
    /isSegmentVideoTask/ {if (region && NR-region < 80) {found=1}}
    END {exit !found}
  ' "$TASKITEM"; then
    GF=15
    echo "PASS: mobile branch routes segment videos"
  else
    # Fallback: any unified hook handles mobile + segment routing
    if grep -rE "handleMobileTap" src/shared/components/TasksPane 2>/dev/null | grep -q "."; then
      if grep -rE "isSegmentVideoTask" src/shared/components/TasksPane 2>/dev/null | wc -l | awk '{exit !($1>=2)}'; then
        GF=8
        echo "PARTIAL: segment routing referenced multiple times (likely covers mobile)"
      fi
    fi
  fi
fi
add $GF

###############################################################################
# Gate G (F2P, 0.10): Useful navigation state — matches what the destination
# (useSegmentSlotMode in ShotImagesEditor) reads. Probe consumer side.
###############################################################################
echo "=== Gate G: deep-link state shape compatible with consumer (F2P, 0.10) ==="
GG=0
CONSUMER="src/tools/travel-between-images/components/ShotImagesEditor/hooks/useSegmentSlotMode.ts"
if [ -f "$CONSUMER" ]; then
  # consumer reads state.openSegmentSlot — producer must set it (if using nav strategy)
  if grep -q "openSegmentSlot" "$CONSUMER"; then
    if grep -rE "openSegmentSlot\s*:" src/shared/components/TasksPane src/shared/hooks 2>/dev/null | grep -q "."; then
      GG=10
      echo "PASS: producer sets openSegmentSlot consumed by ShotImagesEditor"
    else
      # Acceptable alternate: in-place lightbox path doesn't need nav state
      if has_ml_prop "$TASKSPANE" "segmentSlotMode" || has_ml_prop "$TASKSPANE" "shotId"; then
        GG=10
        echo "PASS: in-place lightbox bypasses nav state (acceptable)"
      else
        echo "FAIL: no openSegmentSlot producer and no in-place lightbox"
      fi
    fi
  fi
fi
add $GG

###############################################################################
echo ""
echo "=== Final reward ==="
cat "$REWARD_FILE"
echo ""
exit 0