#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
mkdir -p /logs/verifier
REWARD="0.00"
echo "$REWARD" > "$REWARD_FILE"

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if ! command -v node >/dev/null 2>&1; then
  for p in /root/.nvm/versions/node/*/bin /usr/local/node/bin; do
    [ -d "$p" ] && export PATH="$p:$PATH"
  done
fi

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
    if [ -d "$d/src" ] && [ -d "$d/src/shared" ]; then REPO="${d%/}"; break; fi
  done
fi
echo "Using REPO=$REPO"
[ -z "$REPO" ] && { echo "0.00" > "$REWARD_FILE"; exit 0; }
cd "$REPO" || { echo "0.00" > "$REWARD_FILE"; exit 0; }

TASKSPANE="src/shared/components/TasksPane/TasksPane.tsx"
TASKITEM="src/shared/components/TasksPane/TaskItem.tsx"
TASK_UTILS="src/shared/components/TasksPane/utils/task-utils.ts"
SOS="src/tools/travel-between-images/components/Timeline/SegmentOutputStrip.tsx"
TASKSPANE_DIR="src/shared/components/TasksPane"
SLOT_HOOK="src/tools/travel-between-images/components/ShotImagesEditor/hooks/useSegmentSlotMode.ts"

###############################################################################
# P2P regression gates (no reward, diagnostic/penalty only)
###############################################################################

# P2P: SegmentOutputStrip still exists and references shotId
if [ ! -f "$SOS" ] || ! grep -q "shotId" "$SOS"; then
  echo "P2P FAIL: SegmentOutputStrip.tsx missing or lost shotId"
  echo "0.00" > "$REWARD_FILE"; exit 0
fi

# P2P: task-utils still exports the helpers used downstream
if [ ! -f "$TASK_UTILS" ]; then
  echo "P2P FAIL: task-utils missing"
  echo "0.00" > "$REWARD_FILE"; exit 0
fi
for sym in "isSegmentVideoTask" "extractPairShotGenerationId" "extractShotId"; do
  if ! grep -q "$sym" "$TASK_UTILS"; then
    echo "P2P FAIL: $sym missing from task-utils"
    echo "0.00" > "$REWARD_FILE"; exit 0
  fi
done

# Detect Task field name (camelCase taskType vs snake task_type)
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
# F2P Gates — total weight = 1.0
###############################################################################

# Weights (rebalanced — behavioral gates dominate, structural greps capped):
#   G1  isSegmentVideoTask uses correct field (behavioral, executed)   0.45
#   G2  isSegmentVideoTask gates routing in TasksPane (call-site)      0.025  (structural grep)
#   G3  Shot-context routing exists & is reachable                     0.025  (structural grep)
#       (deep-link nav OR in-place segmentSlot lightbox)
#   G4  extractPairShotGenerationId returns expected id (behavioral)   0.45
#   G5  Receiver wiring: useSegmentSlotMode handles openSegmentSlot    0.025  (structural grep)
#       OR a dedicated SegmentSlot lightbox hook for TasksPane exists
#   G6  Completeness: ≥2 of {task-utils, TaskItem/TasksPane,            0.025  (structural grep)
#       useSegmentSlotMode/SegmentSlotTaskLightbox} touched
#       AND non-trivial line counts in those touched files
#
# Total = 1.00

SCORE=0

###############################################################################
# G1 — Behavioral: actually evaluate isSegmentVideoTask in node
###############################################################################
echo "=== G1: isSegmentVideoTask returns true for individual_travel_segment (0.45) ==="
G1=0
if [ -f "$TASK_UTILS" ] && command -v node >/dev/null 2>&1; then
  TMPJS=$(mktemp /tmp/tu_XXXXXX.mjs)
  # Strip TS types crudely so node can run it. We only need the body.
  # Extract isSegmentVideoTask body and rebuild as plain JS.
  BODY=$(awk '
    /export const isSegmentVideoTask/ { capture=1 }
    capture { print }
    capture && /^};?\s*$/ { capture=0 }
  ' "$TASK_UTILS")

  echo "--- isSegmentVideoTask source ---"
  echo "$BODY"
  echo "--- end ---"

  # Convert TS arrow with type annotations into JS
  JS_BODY=$(echo "$BODY" \
    | sed -E 's/:\s*Task//g' \
    | sed -E 's/:\s*boolean//g' \
    | sed 's/^export //')

  cat > "$TMPJS" <<EOF
$JS_BODY

const taskCamel = { taskType: 'individual_travel_segment', task_type: 'individual_travel_segment' };
const taskSnakeOnly = { task_type: 'individual_travel_segment' };
const taskCamelOnly = { taskType: 'individual_travel_segment' };
const wrongType = { taskType: 'travel_orchestrator', task_type: 'travel_orchestrator' };

const expectedField = '$TASK_FIELD';
let okPositive = false;
let okNegative = false;
try { okPositive = isSegmentVideoTask(taskCamel) === true; } catch (e) { console.error('positive call threw:', e.message); }
try { okNegative = isSegmentVideoTask(wrongType) === false; } catch (e) { console.error('negative call threw:', e.message); }

// More importantly: does it work when ONLY the Type-defined field is set?
let okFieldMatches = false;
try {
  const onlyCorrect = expectedField === 'taskType' ? taskCamelOnly : taskSnakeOnly;
  okFieldMatches = isSegmentVideoTask(onlyCorrect) === true;
} catch (e) { console.error('field-match call threw:', e.message); }

console.log(JSON.stringify({ okPositive, okNegative, okFieldMatches }));
EOF

  OUT=$(node "$TMPJS" 2>&1)
  echo "G1 output: $OUT"
  rm -f "$TMPJS"

  if echo "$OUT" | grep -q '"okFieldMatches":true' \
     && echo "$OUT" | grep -q '"okPositive":true' \
     && echo "$OUT" | grep -q '"okNegative":true'; then
    echo "G1 PASS"
    G1=450
  else
    echo "G1 FAIL"
  fi
else
  echo "G1 SKIP (no node or task-utils missing)"
fi
SCORE=$((SCORE+G1))

###############################################################################
# G2 — isSegmentVideoTask CALLED inside TasksPane component tree
###############################################################################
echo "=== G2: isSegmentVideoTask gates routing at call-site (0.025) ==="
G2=0
CALL_HITS=$(grep -rEn "isSegmentVideoTask\s*\(" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null \
  | grep -v "export const isSegmentVideoTask" \
  | grep -v "export function isSegmentVideoTask" \
  | wc -l)
echo "isSegmentVideoTask call-site count: $CALL_HITS"
if [ "$CALL_HITS" -ge 1 ]; then
  G2=25
  echo "G2 PASS"
else
  echo "G2 FAIL"
fi
SCORE=$((SCORE+G2))

###############################################################################
# G3 — Shot-context routing wired in TasksPane (deep-link OR in-place)
###############################################################################
echo "=== G3: shot-context routing exists in TasksPane (0.025) ==="
G3=0

# Strategy A: navigation to /tools/travel-between-images#<shotId> with openSegmentSlot
NAV_HIT=$(grep -rEn "travel-between-images#" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null | wc -l)
SLOT_PAYLOAD=$(grep -rEn "openSegmentSlot" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null | wc -l)
A_OK=0
if [ "$NAV_HIT" -ge 1 ] && [ "$SLOT_PAYLOAD" -ge 1 ]; then
  A_OK=1
fi

# Strategy B: in-place MediaLightbox with segmentSlotMode / segmentSlotModeData / shot context
B_OK=0
if grep -rEn "segmentSlotMode|SegmentSlotModeData|currentSegmentImages" "$TASKSPANE_DIR" 2>/dev/null | grep -q .; then
  B_OK=1
fi

echo "Strategy A (deep-link)=$A_OK  Strategy B (in-place)=$B_OK"
if [ $A_OK -eq 1 ] || [ $B_OK -eq 1 ]; then
  # Strategy must be reachable from a place that's gated by isSegmentVideoTask.
  # Check: in the same file as a call to isSegmentVideoTask, the routing exists.
  GATED_OK=0
  for f in $(grep -rl "isSegmentVideoTask\s*(" "$TASKSPANE_DIR" 2>/dev/null); do
    if grep -qE "openSegmentSlot|segmentSlotMode|SegmentSlotModeData" "$f"; then
      GATED_OK=1
      echo "Routing gated by isSegmentVideoTask in: $f"
      break
    fi
  done
  if [ $GATED_OK -eq 1 ]; then
    G3=25
    echo "G3 PASS"
  else
    echo "G3 PARTIAL: routing exists but not co-located with isSegmentVideoTask gate"
    G3=12
  fi
else
  echo "G3 FAIL"
fi
SCORE=$((SCORE+G3))

###############################################################################
# G4 — Behavioral: extractPairShotGenerationId returns expected id
###############################################################################
echo "=== G4: extractPairShotGenerationId returns correct id (0.45) ==="
G4=0
if [ -f "$TASK_UTILS" ] && command -v node >/dev/null 2>&1; then
  TMPJS=$(mktemp /tmp/ep_XXXXXX.mjs)

  # Pull just the body of extractPairShotGenerationId by line range.
  START=$(grep -nE "export const extractPairShotGenerationId|export function extractPairShotGenerationId" "$TASK_UTILS" | head -1 | cut -d: -f1)
  if [ -n "$START" ]; then
    # Find next "^};" or "^}" after START
    END=$(awk -v s="$START" 'NR>=s && /^};?\s*$/ {print NR; exit}' "$TASK_UTILS")
    if [ -n "$END" ]; then
      sed -n "${START},${END}p" "$TASK_UTILS" > /tmp/_body.ts
      JS_BODY=$(sed -E 's/:\s*[A-Za-z_<>\|\[\]\? ]+(\s*=)/\1/g; s/ as [A-Za-z_<>\|\[\] ]+//g; s/^export //' /tmp/_body.ts)

      cat > "$TMPJS" <<EOF
$JS_BODY

// Test 1: top-level params.pair_shot_generation_id wins
const t1 = { params: { pair_shot_generation_id: 'aaaaaaaa-1111' } };
// Test 2: nested individual_segment_params
const t2 = { params: { individual_segment_params: { pair_shot_generation_id: 'bbbbbbbb-2222' } } };
// Test 3: orchestrator_details.pair_shot_generation_ids[segment_index]
const t3 = { params: { segment_index: 2, orchestrator_details: { pair_shot_generation_ids: ['x0','x1','cccccccc-3333','x3'] } } };
// Test 4: nothing → null
const t4 = { params: {} };

const r1 = extractPairShotGenerationId(t1);
const r2 = extractPairShotGenerationId(t2);
const r3 = extractPairShotGenerationId(t3);
const r4 = extractPairShotGenerationId(t4);
console.log(JSON.stringify({ r1, r2, r3, r4 }));
EOF
      OUT=$(node "$TMPJS" 2>&1)
      echo "G4 output: $OUT"
      rm -f "$TMPJS" /tmp/_body.ts

      OK=0
      echo "$OUT" | grep -q '"r1":"aaaaaaaa-1111"' && OK=$((OK+1))
      echo "$OUT" | grep -q '"r2":"bbbbbbbb-2222"' && OK=$((OK+1))
      echo "$OUT" | grep -q '"r3":"cccccccc-3333"' && OK=$((OK+1))
      echo "$OUT" | grep -q '"r4":null' && OK=$((OK+1))
      echo "G4 sub-checks passed: $OK/4"
      if [ $OK -ge 3 ]; then
        G4=450
        echo "G4 PASS"
      elif [ $OK -ge 2 ]; then
        G4=225
        echo "G4 PARTIAL"
      fi
    fi
  fi
else
  echo "G4 SKIP"
fi
SCORE=$((SCORE+G4))

###############################################################################
# G5 — Receiver wiring (handles the open-on-arrival)
###############################################################################
echo "=== G5: receiver wiring for shot-context open (0.025) ==="
G5=0

# Path A: useSegmentSlotMode reads location.state.openSegmentSlot
A=0
if [ -f "$SLOT_HOOK" ]; then
  if grep -qE "openSegmentSlot" "$SLOT_HOOK" && \
     grep -qE "setActivePairData|setSegmentSlotLightboxIndex|pairDataByIndex|startImage" "$SLOT_HOOK"; then
    A=1
  fi
fi

# Path B: TasksPane has its own SegmentSlot lightbox hook that opens MediaLightbox
B=0
if find "$TASKSPANE_DIR" -name '*.ts' -o -name '*.tsx' 2>/dev/null \
    | xargs grep -lE "useSegmentSlotTaskLightbox|segmentSlotModeData|SegmentSlotModeData" 2>/dev/null \
    | grep -q .; then
  B=1
fi

# Path C: TasksPane navigates with openSegmentSlot AND useSegmentSlotMode (already in repo) handles it
C=0
if grep -rqE "openSegmentSlot" "$TASKSPANE_DIR" 2>/dev/null \
   && [ -f "$SLOT_HOOK" ] && grep -q "openSegmentSlot" "$SLOT_HOOK"; then
  C=1
fi

echo "Receiver paths: A=$A B=$B C=$C"
if [ $A -eq 1 ] || [ $B -eq 1 ] || [ $C -eq 1 ]; then
  G5=25
  echo "G5 PASS"
else
  echo "G5 FAIL"
fi
SCORE=$((SCORE+G5))

###############################################################################
# G6 — Completeness via heuristic file-touch detection
###############################################################################
echo "=== G6: completeness across required files (0.025) ==="
G6=0

# Capture line counts (proxy for "was edited / non-trivial")
TASK_UTILS_LC=$(wc -l < "$TASK_UTILS" 2>/dev/null || echo 0)

# 1) task-utils references taskType (the bug fix marker)
T1=0
if grep -qE "task\.${TASK_FIELD}\s*===\s*['\"]individual_travel_segment['\"]" "$TASK_UTILS"; then
  T1=1
fi

# 2) TasksPane component tree wires routing for segment videos
T2=0
if grep -rqE "isSegmentVideoTask\s*\(" "$TASKSPANE_DIR" 2>/dev/null \
   && grep -rqE "openSegmentSlot|segmentSlotMode|SegmentSlotModeData" "$TASKSPANE_DIR" src/shared/hooks 2>/dev/null; then
  T2=1
fi

# 3) Receiver side updated OR a TasksPane-local segment lightbox exists
T3=0
if [ -f "$SLOT_HOOK" ] && grep -q "openSegmentSlot" "$SLOT_HOOK"; then
  T3=1
fi
if find "$TASKSPANE_DIR" -name '*.ts' -o -name '*.tsx' 2>/dev/null \
    | xargs grep -lE "useSegmentSlotTaskLightbox|segmentSlotModeData" 2>/dev/null \
    | grep -q .; then
  T3=1
fi

TOUCHED=$((T1+T2+T3))
echo "Completeness components met: T1=$T1 T2=$T2 T3=$T3 (sum=$TOUCHED)"
if [ $TOUCHED -ge 3 ]; then
  G6=25
elif [ $TOUCHED -eq 2 ]; then
  G6=13
elif [ $TOUCHED -eq 1 ]; then
  G6=5
fi
SCORE=$((SCORE+G6))

###############################################################################
# Run any existing vitest tests for TasksPane / segment slot if present (P2P-ish bonus weight 0)
# We do not add reward, but we DO short-circuit if existing tests fail.
###############################################################################
if [ -f package.json ] && command -v npx >/dev/null 2>&1; then
  TEST_FILES=$(find src/shared/components/TasksPane src/tools/travel-between-images -name '*.test.ts*' 2>/dev/null | head -5)
  if [ -n "$TEST_FILES" ]; then
    echo "=== Running existing tests (P2P regression only): ==="
    echo "$TEST_FILES"
    timeout 90 npx vitest run $TEST_FILES --reporter=basic >/tmp/vitest.out 2>&1
    RC=$?
    head -80 /tmp/vitest.out
    if [ $RC -ne 0 ] && grep -qE "FAIL|failed" /tmp/vitest.out; then
      echo "P2P FAIL: existing tests broken"
      echo "0.00" > "$REWARD_FILE"
      exit 0
    fi
  fi
fi

###############################################################################
# Compute final reward
###############################################################################
# SCORE is in units of 1/1000. Convert to 0.000–1.000.
echo "G1=$G1 G2=$G2 G3=$G3 G4=$G4 G5=$G5 G6=$G6 SCORE=$SCORE/1000"
REWARD=$(awk -v s="$SCORE" 'BEGIN { printf "%.3f", s/1000.0 }')
echo "FINAL REWARD: $REWARD"
echo "$REWARD" > /logs/verifier/reward.txt