#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD="0.00"
echo "$REWARD" > "$REWARD_FILE"

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

TASKSPANE="src/shared/components/TasksPane/TasksPane.tsx"
TASKITEM="src/shared/components/TasksPane/TaskItem.tsx"
TASK_UTILS="src/shared/components/TasksPane/utils/task-utils.ts"
SOS="src/tools/travel-between-images/components/Timeline/SegmentOutputStrip.tsx"
TASKSPANE_DIR="src/shared/components/TasksPane"

###############################################################################
# Hard P2P gate: SegmentOutputStrip must still pass shotId to MediaLightbox.
# This passes on base (no-op) — used purely as regression guard.
###############################################################################
if [ ! -f "$SOS" ]; then
  echo "Missing $SOS — bailing"
  echo "0.00" > "$REWARD_FILE"
  exit 0
fi
if ! grep -q "shotId" "$SOS"; then
  echo "P2P FAIL: SegmentOutputStrip lost shotId — regression"
  echo "0.00" > "$REWARD_FILE"
  exit 0
fi

###############################################################################
# Hard P2P gate: Task type field. Determine the correct field name on Task type.
# Used as a regression guard only (no reward).
###############################################################################
TYPE_FILE=""
for f in src/types/tasks.ts src/types/Task.ts; do
  [ -f "$f" ] && TYPE_FILE="$f" && break
done
if [ -z "$TYPE_FILE" ]; then
  TYPE_FILE=$(grep -rl "interface Task " src/types 2>/dev/null | head -1)
fi
TASK_FIELD="taskType"
if [ -n "$TYPE_FILE" ] && [ -f "$TYPE_FILE" ]; then
  if grep -qE "^\s*taskType\s*[:?]" "$TYPE_FILE"; then
    TASK_FIELD="taskType"
  elif grep -qE "^\s*task_type\s*[:?]" "$TYPE_FILE"; then
    TASK_FIELD="task_type"
  fi
fi
echo "Detected Task field: $TASK_FIELD (from $TYPE_FILE)"

###############################################################################
# Determine the BASE-state of isSegmentVideoTask: is the bug present?
# The bug (per the task and confirmed by all 5 agents): isSegmentVideoTask
# uses `task.task_type` while the Task type defines `taskType` (camelCase),
# so the function ALWAYS returns false → segment-video click handler is dead
# code → lightbox opens without shot context.
#
# F2P signal: isSegmentVideoTask must reference task.<TASK_FIELD> matching
# the Task type. On the buggy base it does NOT (uses wrong key); on the fix
# it does. Award only if this is FIXED.
###############################################################################
echo "=== F2P Gate 1: isSegmentVideoTask uses correct field name (0.30) ==="
G1=0
if [ -f "$TASK_UTILS" ]; then
  # Extract just the isSegmentVideoTask body
  BODY=$(awk '/isSegmentVideoTask/,/^};/' "$TASK_UTILS" | head -20)
  echo "--- isSegmentVideoTask body ---"
  echo "$BODY"
  echo "--- end ---"
  if echo "$BODY" | grep -qE "task\.${TASK_FIELD}\s*===\s*['\"]individual_travel_segment['\"]"; then
    echo "PASS: isSegmentVideoTask uses task.${TASK_FIELD}"
    G1=30
  else
    echo "FAIL: isSegmentVideoTask not using task.${TASK_FIELD}"
  fi
else
  echo "FAIL: $TASK_UTILS missing"
fi

###############################################################################
# F2P Gate 2: Segment-video routing wired into TasksPane click flow.
# On the buggy base, even when isSegmentVideoTask was correct, there was
# no shot-context routing in TasksPane. Two acceptable fixes:
#   (A) Navigate to /tools/travel-between-images#<shotId> with state carrying
#       openSegmentSlot / fromShotClick (deep-link to ShotImagesEditor).
#   (B) Open MediaLightbox locally with shot-context props (segmentSlotMode
#       or shotId+currentSegmentImages).
#
# Must be GATED by isSegmentVideoTask call inside TasksPane component tree.
###############################################################################
echo "=== F2P Gate 2: shot-context routing wired in TasksPane (0.40) ==="
G2=0
ROUTING=0

# Strategy A: deep-link navigation with openSegmentSlot
if grep -rE "travel-between-images#" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null | grep -q .; then
  if grep -rE "openSegmentSlot|fromShotClick" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null | grep -q .; then
    ROUTING=$((ROUTING+1))
    echo "Found strategy A: deep-link navigation"
  fi
fi

# Strategy B: in-place lightbox with shot context props
ML_PROBE='
const ts=require("typescript");
const fs=require("fs");
const path=process.argv[1];
if(!fs.existsSync(path)){console.log("[]"); process.exit(0);}
const src=fs.readFileSync(path,"utf8");
const sf=ts.createSourceFile("f.tsx",src,ts.ScriptTarget.Latest,true,ts.ScriptKind.TSX);
const elems=[];
(function v(n){
  if(ts.isJsxOpeningElement(n)||ts.isJsxSelfClosingElement(n)){
    const tag=n.tagName.getText(sf);
    if(tag==="MediaLightbox"){
      const props=[];
      if(n.attributes&&n.attributes.properties){
        n.attributes.properties.forEach(x=>{
          if(ts.isJsxAttribute(x)&&x.name) props.push(x.name.getText(sf));
        });
      }
      elems.push(props);
    }
  }
  ts.forEachChild(n,v);
})(sf);
console.log(JSON.stringify(elems));
'

ML_HIT=0
if command -v node >/dev/null 2>&1 && [ -d node_modules/typescript ]; then
  for f in $(find "$TASKSPANE_DIR" -name '*.tsx' -o -name '*.ts' 2>/dev/null); do
    OUT=$(node -e "$ML_PROBE" "$f" 2>/dev/null)
    if echo "$OUT" | grep -qE 'segmentSlotMode|currentSegmentImages|"shotId"'; then
      ML_HIT=1
      echo "Found strategy B in $f: $OUT"
      break
    fi
  done
fi
if [ $ML_HIT -eq 1 ]; then
  ROUTING=$((ROUTING+1))
fi

# Confirm gating: isSegmentVideoTask is CALLED (not just defined) somewhere in
# TasksPane / shared hooks
GATED=0
CALL_HITS=$(grep -rE "isSegmentVideoTask\s*\(" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null \
  | grep -v "export const isSegmentVideoTask" \
  | grep -v "export function isSegmentVideoTask" \
  | wc -l)
if [ "$CALL_HITS" -gt 0 ]; then
  GATED=1
fi
echo "routing strategies=$ROUTING, gated_calls=$CALL_HITS"

# To get full credit: routing wired AND gated by isSegmentVideoTask.
# Note: on the buggy base, although there IS a `if (isSegmentVideoTask(task) && shotId)`
# in TaskItem.tsx already, the function returns false (G1 fails). So G2 alone
# isn't enough to fix the bug. We award G2 only if routing is present.
# But the routing exists in the base TaskItem.tsx already, so we need a stricter check.

# Stricter F2P: the routing must be REACHABLE. We test by checking BOTH:
#   - G1 passes (taskType correct), AND
#   - routing exists with gating.
# We award G2 only when routing is gated AND isSegmentVideoTask is correct.
if [ $ROUTING -ge 1 ] && [ $GATED -eq 1 ] && [ $G1 -eq 30 ]; then
  G2=40
  echo "PASS: shot-context routing reachable (isSegmentVideoTask correct + gated routing present)"
elif [ $ROUTING -ge 1 ] && [ $GATED -eq 1 ]; then
  echo "ROUTING present and gated, but isSegmentVideoTask still buggy → routing is dead code → no credit"
  G2=0
else
  echo "FAIL: routing not wired"
fi

###############################################################################
# F2P Gate 3: TypeScript still compiles after the changes.
# This is BEHAVIORAL: a real fix that introduces new props/state must still type-check.
# To avoid awarding the no-op base, we ONLY count this when G1 has been fixed
# (i.e. the agent did real work). Otherwise no credit even if base compiles.
###############################################################################
echo "=== F2P Gate 3: TS compiles after fix (0.20) ==="
G3=0
if [ $G1 -eq 30 ]; then
  TSC_OUT=$(mktemp)
  TSC_EXIT=127
  if [ -x node_modules/.bin/tsc ]; then
    node_modules/.bin/tsc --noEmit > "$TSC_OUT" 2>&1
    TSC_EXIT=$?
  elif [ -f node_modules/typescript/bin/tsc ]; then
    node node_modules/typescript/bin/tsc --noEmit > "$TSC_OUT" 2>&1
    TSC_EXIT=$?
  elif command -v npx >/dev/null 2>&1; then
    npx --no-install tsc --noEmit > "$TSC_OUT" 2>&1
    TSC_EXIT=$?
  fi
  ERR_COUNT=$(grep -cE "error TS[0-9]+" "$TSC_OUT" 2>/dev/null)
  [ -z "$ERR_COUNT" ] && ERR_COUNT=0
  echo "tsc exit=$TSC_EXIT err_count=$ERR_COUNT"
  tail -30 "$TSC_OUT"
  if [ "$TSC_EXIT" = "0" ]; then
    G3=20
  elif [ "$ERR_COUNT" -le 2 ]; then
    G3=10
  fi
  rm -f "$TSC_OUT"
else
  echo "Skipped (G1 not fixed → no credit even if base compiles)"
fi

###############################################################################
# F2P Gate 4: TaskItem actually invokes the segment-video routing path.
# Must contain a call to isSegmentVideoTask gated with shotId AND a code path
# that either navigates to travel-between-images OR opens segmentSlotMode lightbox.
# Award only when G1 fixed (otherwise dead code).
###############################################################################
echo "=== F2P Gate 4: TaskItem invokes shot-context path (0.10) ==="
G4=0
if [ $G1 -eq 30 ] && [ -f "$TASKITEM" ]; then
  if grep -qE "isSegmentVideoTask\s*\(\s*task\s*\)" "$TASKITEM" && \
     grep -qE "shotId" "$TASKITEM"; then
    if grep -qE "travel-between-images" "$TASKITEM" || \
       grep -qE "openSegmentSlot|segmentSlotMode|openSegmentSlotLightbox" "$TASKITEM"; then
      G4=10
      echo "PASS: TaskItem has gated shot-context path"
    fi
  fi
fi

###############################################################################
# Total
###############################################################################
TOTAL=$((G1 + G2 + G3 + G4))
echo "G1=$G1 G2=$G2 G3=$G3 G4=$G4 TOTAL=$TOTAL"
REWARD=$(awk "BEGIN {printf \"%.2f\", $TOTAL/100}")
echo "REWARD=$REWARD"
echo "$REWARD" > "$REWARD_FILE"