#!/bin/bash
set +e

mkdir -p /logs/verifier
GATES_FILE=/logs/verifier/gates.json
REWARD_FILE=/logs/verifier/reward.txt
: > "$GATES_FILE"
printf "%.4f\n" 0 > "$REWARD_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail="${detail//\"/\'}"
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

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

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    emit p2p_segment_output_strip_intact false "no repo"
    emit p2p_task_utils_exports_intact false "no repo"
    emit p2p_enhance_prompt_default_unchanged true "no repo"
    emit p2p_src_unmodified_check true "no repo"
    emit t1_f2p_is_segment_video_task_field false "no repo"
    emit t1_f2p_extract_pair_shot_id false "no repo"
    emit t1_f2p_lightbox_receives_segment_context false "no repo"
    emit t3_f2p_orphan_fallback_branch false "no repo"
    printf "%.4f\n" 0 > "$REWARD_FILE"
    exit 0
fi
cd "$REPO" || exit 0

TASKSPANE_DIR="src/shared/components/TasksPane"
TASK_UTILS="src/shared/components/TasksPane/utils/task-utils.ts"
SOS="src/tools/travel-between-images/components/Timeline/SegmentOutputStrip.tsx"

###############################################################################
# P2P gates (gating only)
###############################################################################

# p2p_segment_output_strip_intact
if [ -f "$SOS" ] && grep -q "shotId" "$SOS"; then
    emit p2p_segment_output_strip_intact true ""
    P2P_SOS=1
else
    emit p2p_segment_output_strip_intact false "SegmentOutputStrip missing or lost shotId"
    P2P_SOS=0
fi

# p2p_task_utils_exports_intact
P2P_TU=1
if [ ! -f "$TASK_UTILS" ]; then
    P2P_TU=0
    emit p2p_task_utils_exports_intact false "task-utils missing"
else
    MISSING=""
    for sym in "isSegmentVideoTask" "extractPairShotGenerationId" "extractShotId"; do
        if ! grep -q "$sym" "$TASK_UTILS"; then
            MISSING="$MISSING $sym"
            P2P_TU=0
        fi
    done
    if [ $P2P_TU -eq 1 ]; then
        emit p2p_task_utils_exports_intact true ""
    else
        emit p2p_task_utils_exports_intact false "missing:$MISSING"
    fi
fi

# p2p_enhance_prompt_default_unchanged — make sure unrelated regression isn't introduced
P2P_EP=1
EP_DETAIL=""
JCP="src/tools/join-clips/pages/JoinClipsPage.tsx"
JMC="src/tools/join-clips/components/JoinModeContent.tsx"
# search broadly: not all repos may have these exact paths; only check files that exist
for f in "$JCP" "$JMC"; do
    if [ -f "$f" ]; then
        # If the file mentions enhancePrompt, the default *if specified* should still be false.
        # We only fail if we find an explicit `enhancePrompt = true` or `enhancePrompt: ... = true` default.
        if grep -nE "enhancePrompt[[:space:]]*=[[:space:]]*true" "$f" >/dev/null 2>&1 \
           || grep -nE "enhancePrompt:[^=]*=[[:space:]]*true" "$f" >/dev/null 2>&1; then
            P2P_EP=0
            EP_DETAIL="$f flipped enhancePrompt default to true"
        fi
    fi
done
if [ $P2P_EP -eq 1 ]; then
    emit p2p_enhance_prompt_default_unchanged true ""
else
    emit p2p_enhance_prompt_default_unchanged false "$EP_DETAIL"
fi

# p2p_src_unmodified_check — degrades to pass without baseline (this task DOES allow src edits, so we don't gate on it strongly).
# Always emit pass — included for manifest parity but does not block.
emit p2p_src_unmodified_check true "task allows source edits"

###############################################################################
# Detect Task field name (for behavioral gate)
###############################################################################
TYPE_FILE=""
for f in src/types/tasks.ts src/types/Task.ts src/types/index.ts; do
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
# t1_f2p_is_segment_video_task_field — BEHAVIORAL
###############################################################################
G1_PASS=false
G1_DETAIL=""
if [ -f "$TASK_UTILS" ] && command -v node >/dev/null 2>&1; then
    TMPJS=$(mktemp /tmp/tu_XXXXXX.mjs)

    # Extract the function source — handle both `export const` and `export function`.
    BODY=$(awk '
      /export[[:space:]]+const[[:space:]]+isSegmentVideoTask/ { capture=1; brace=0 }
      /export[[:space:]]+function[[:space:]]+isSegmentVideoTask/ { capture=1; brace=0 }
      capture {
        print
        for (i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")brace++; else if(c=="}"){brace--; if(brace==0 && capture){capture=0; nextfile_signal=1}}}
      }
    ' "$TASK_UTILS")

    if [ -z "$BODY" ]; then
        # fallback: capture from declaration to first `};` at line start
        BODY=$(awk '
          /export[[:space:]]+(const|function)[[:space:]]+isSegmentVideoTask/ { capture=1 }
          capture { print }
          capture && /^\};?$/ { capture=0 }
        ' "$TASK_UTILS")
    fi

    # Strip TS type annotations crudely
    JS_BODY=$(echo "$BODY" \
      | sed -E 's/:\s*Task[A-Za-z_]*//g' \
      | sed -E 's/:\s*boolean//g' \
      | sed -E 's/:\s*string//g' \
      | sed 's/^export //')

    cat > "$TMPJS" <<EOF
$JS_BODY

const taskCamelOnly = { taskType: 'individual_travel_segment' };
const taskSnakeOnly = { task_type: 'individual_travel_segment' };
const taskBoth = { taskType: 'individual_travel_segment', task_type: 'individual_travel_segment' };
const wrong = { taskType: 'travel_orchestrator', task_type: 'travel_orchestrator' };

const expectedField = '$TASK_FIELD';
let okPositive = false;
let okNegative = false;
let okFieldMatches = false;
try { okPositive = isSegmentVideoTask(taskBoth) === true; } catch (e) { console.error('positive threw:', e.message); }
try { okNegative = isSegmentVideoTask(wrong) === false; } catch (e) { console.error('negative threw:', e.message); }
try {
  const onlyCorrect = expectedField === 'taskType' ? taskCamelOnly : taskSnakeOnly;
  okFieldMatches = isSegmentVideoTask(onlyCorrect) === true;
} catch (e) { console.error('field-match threw:', e.message); }

console.log(JSON.stringify({ okPositive, okNegative, okFieldMatches }));
EOF

    OUT=$(node "$TMPJS" 2>&1)
    echo "G1 output: $OUT"
    rm -f "$TMPJS"

    if echo "$OUT" | grep -q '"okFieldMatches":true' \
       && echo "$OUT" | grep -q '"okPositive":true' \
       && echo "$OUT" | grep -q '"okNegative":true'; then
        G1_PASS=true
    else
        G1_DETAIL="behavioral check failed: $OUT"
    fi
else
    G1_DETAIL="task-utils or node missing"
fi
if [ "$G1_PASS" = true ]; then
    emit t1_f2p_is_segment_video_task_field true ""
else
    emit t1_f2p_is_segment_video_task_field false "$G1_DETAIL"
fi

###############################################################################
# t1_f2p_extract_pair_shot_id — BEHAVIORAL
# Run extractPairShotGenerationId AND/OR extractShotId on a fixture; expect a
# non-null/non-empty result for the fixture id.
###############################################################################
G2_PASS=false
G2_DETAIL=""
if [ -f "$TASK_UTILS" ] && command -v node >/dev/null 2>&1; then
    TMPJS=$(mktemp /tmp/ep_XXXXXX.mjs)

    # Pull the helper bodies. We extract everything between the start of each
    # function declaration and the next blank line followed by `export` (loose).
    AWKPROG='
      function emit_block(){if(buf!="")print buf; buf=""}
      /^export[[:space:]]+(const|function)[[:space:]]+extractPairShotGenerationId/ { emit_block(); capture=1 }
      /^export[[:space:]]+(const|function)[[:space:]]+extractShotId/ { emit_block(); capture=1 }
      capture { buf = buf $0 "\n" }
      capture && /^\};?$/ { capture=0; emit_block() }
      END { emit_block() }
    '
    BODIES=$(awk "$AWKPROG" "$TASK_UTILS")

    JS_BODIES=$(echo "$BODIES" \
      | sed -E 's/:\s*Task[A-Za-z_]*//g' \
      | sed -E 's/:\s*string\s*\|\s*null//g' \
      | sed -E 's/:\s*string//g' \
      | sed -E 's/:\s*boolean//g' \
      | sed -E 's/:\s*any//g' \
      | sed 's/^export //')

    cat > "$TMPJS" <<EOF
$JS_BODIES

// Build a fixture that any reasonable implementation should accept.
// Real tasks have nested params with shot_generation_id / parent_generation_id /
// pair_shot_generation_id and a top-level shot_id / shotId.
const fixture = {
  id: 'task-1',
  taskType: 'individual_travel_segment',
  task_type: 'individual_travel_segment',
  shotId: 'shot-abc-123',
  shot_id: 'shot-abc-123',
  params: {
    shotId: 'shot-abc-123',
    shot_id: 'shot-abc-123',
    pair_shot_generation_id: 'pair-xyz-999',
    pairShotGenerationId: 'pair-xyz-999',
    parent_generation_id: 'pair-xyz-999',
    parentGenerationId: 'pair-xyz-999',
    shot_generation_id: 'pair-xyz-999',
    shotGenerationId: 'pair-xyz-999',
  },
};

let pairOk = false;
let shotOk = false;
try {
  if (typeof extractPairShotGenerationId === 'function') {
    const v = extractPairShotGenerationId(fixture);
    pairOk = (v === 'pair-xyz-999');
  }
} catch (e) { console.error('pair threw:', e.message); }
try {
  if (typeof extractShotId === 'function') {
    const v = extractShotId(fixture);
    shotOk = (v === 'shot-abc-123');
  }
} catch (e) { console.error('shot threw:', e.message); }

console.log(JSON.stringify({ pairOk, shotOk }));
EOF

    OUT=$(node "$TMPJS" 2>&1)
    echo "G2 output: $OUT"
    rm -f "$TMPJS"

    # Pass if EITHER helper returns the expected id (implementation-agnostic):
    # different patches may use different helper names, but at least one must work.
    if echo "$OUT" | grep -qE '"pairOk":true|"shotOk":true'; then
        G2_PASS=true
    else
        G2_DETAIL="neither helper returned expected id: $OUT"
    fi
else
    G2_DETAIL="task-utils or node missing"
fi
if [ "$G2_PASS" = true ]; then
    emit t1_f2p_extract_pair_shot_id true ""
else
    emit t1_f2p_extract_pair_shot_id false "$G2_DETAIL"
fi

###############################################################################
# t1_f2p_lightbox_receives_segment_context — STATIC-AST behavioral
# Must find a TasksPane file that:
#   (1) calls isSegmentVideoTask(...)  AND
#   (2) renders <MediaLightbox …> (or similar lightbox component) AND
#   (3) passes one of the segment-context props as a JSX expression
#       (currentSegmentImages={…}, segmentSiblings={…}, onNext={…}, hasNext={…},
#        segmentSlotMode, openSegmentSlot)  — must be a JSX prop, not a string
#       literal or comment.
###############################################################################
G3_PASS=false
G3_DETAIL=""
CANDIDATES=$(grep -rl "isSegmentVideoTask" "$TASKSPANE_DIR" 2>/dev/null)
# Also include anywhere TasksPane uses lightbox hooks
CANDIDATES="$CANDIDATES $(grep -rl -E "MediaLightbox|TasksLightbox|SegmentSlot" "$TASKSPANE_DIR" 2>/dev/null)"
CANDIDATES=$(echo "$CANDIDATES" | tr ' ' '\n' | sort -u | grep -v '^$')

GATED_FILE=""
PROPS_FOUND=""
for f in $CANDIDATES; do
    [ -f "$f" ] || continue
    # Strip block comments and line comments (best-effort) to avoid keyword-in-comment gaming.
    STRIPPED=$(sed -E 's://.*$::g' "$f" | awk 'BEGIN{in_block=0} { line=$0; while (match(line, /\/\*.*\*\//)) line=substr(line,1,RSTART-1) substr(line,RSTART+RLENGTH); if(in_block){ if(match(line,/\*\//)){ line=substr(line,RSTART+2); in_block=0 } else next } if(match(line,/\/\*/)){ line=substr(line,1,RSTART-1); in_block=1 } print line }')

    # Must call isSegmentVideoTask (not just import/define)
    HAS_CALL=$(echo "$STRIPPED" | grep -cE "isSegmentVideoTask[[:space:]]*\(" )
    HAS_CALL=$((HAS_CALL))
    # Subtract self-definition mentions
    DEF_CALL=$(echo "$STRIPPED" | grep -cE "(export[[:space:]]+(const|function)[[:space:]]+isSegmentVideoTask|function[[:space:]]+isSegmentVideoTask[[:space:]]*\()")
    EFFECTIVE_CALLS=$((HAS_CALL - DEF_CALL))
    [ $EFFECTIVE_CALLS -le 0 ] && continue

    # Must contain a JSX-prop usage of a segment-context-bearing identifier.
    # Match patterns like:  currentSegmentImages={...}   segmentSiblings={...}   onNext={...}   hasNext={...}
    #                       openSegmentSlot(...)         segmentSlotMode={...}    chevron-related onPrev/onNext
    PROP_HIT=$(echo "$STRIPPED" | grep -cE "\b(currentSegmentImages|segmentSiblings|segmentSlotMode|segmentSlotModeData|openSegmentSlot|onNext|onPrevious|onPrev|hasNext|hasPrevious|hasPrev)[[:space:]]*=[[:space:]]*\{")
    # Or function-call form for openSegmentSlot:
    CALL_HIT=$(echo "$STRIPPED" | grep -cE "\bopenSegmentSlot[[:space:]]*\(")

    if [ "$PROP_HIT" -ge 1 ] || [ "$CALL_HIT" -ge 1 ]; then
        GATED_FILE="$f"
        PROPS_FOUND="prop_hits=$PROP_HIT call_hits=$CALL_HIT"
        break
    fi
done

if [ -n "$GATED_FILE" ]; then
    G3_PASS=true
    G3_DETAIL="$GATED_FILE ($PROPS_FOUND)"
else
    G3_DETAIL="no TasksPane file both calls isSegmentVideoTask AND passes segment-context JSX props"
fi
if [ "$G3_PASS" = true ]; then
    emit t1_f2p_lightbox_receives_segment_context true "$G3_DETAIL"
else
    emit t1_f2p_lightbox_receives_segment_context false "$G3_DETAIL"
fi

###############################################################################
# t3_f2p_orphan_fallback_branch
# Address turn-3: a fallback path for orphan/deleted segments must exist
# alongside the in-context lightbox. Detect TWO distinct render branches in
# TasksPane (e.g., an `if (orphan|fallback|simple) … else …` or two distinct
# lightbox components used conditionally).
###############################################################################
G4_PASS=false
G4_DETAIL=""
# Strip comments before searching
search_files=$(grep -rl -E "MediaLightbox|TasksLightbox|SegmentSlot|isSegmentVideoTask" "$TASKSPANE_DIR" 2>/dev/null)
ORPHAN_FILE=""
for f in $search_files; do
    [ -f "$f" ] || continue
    STRIPPED=$(sed -E 's://.*$::g' "$f")
    # Must reference both an in-context lightbox indicator AND a fallback indicator.
    IN_CTX=$(echo "$STRIPPED" | grep -cE "currentSegmentImages|segmentSiblings|segmentSlotMode|openSegmentSlot|hasNext|onNext")
    FALLBACK=$(echo "$STRIPPED" | grep -cE "fallback|orphan|simple|SimpleLightbox|legacy|deleted|missing")
    if [ "$IN_CTX" -ge 1 ] && [ "$FALLBACK" -ge 1 ]; then
        # Require they appear within a conditional context (ternary or if).
        COND=$(echo "$STRIPPED" | grep -cE "\?\s*<|: *<|if[[:space:]]*\(.*(orphan|fallback|exists|deleted|missing|hasShot|inShot)")
        if [ "$COND" -ge 1 ]; then
            ORPHAN_FILE="$f"
            break
        fi
    fi
done

# Also check hooks dir
if [ -z "$ORPHAN_FILE" ]; then
    for f in $(grep -rl -E "fallback|orphan|simple|SimpleLightbox" src/shared/hooks 2>/dev/null); do
        [ -f "$f" ] || continue
        STRIPPED=$(sed -E 's://.*$::g' "$f")
        IN_CTX=$(echo "$STRIPPED" | grep -cE "currentSegmentImages|segmentSiblings|segmentSlotMode|openSegmentSlot")
        FALLBACK=$(echo "$STRIPPED" | grep -cE "fallback|orphan|simple|SimpleLightbox|legacy|deleted")
        if [ "$IN_CTX" -ge 1 ] && [ "$FALLBACK" -ge 1 ]; then
            ORPHAN_FILE="$f"
            break
        fi
    done
fi

if [ -n "$ORPHAN_FILE" ]; then
    G4_PASS=true
    G4_DETAIL="$ORPHAN_FILE"
else
    G4_DETAIL="no file with both in-context lightbox and orphan/simple fallback branch"
fi
if [ "$G4_PASS" = true ]; then
    emit t3_f2p_orphan_fallback_branch true "$G4_DETAIL"
else
    emit t3_f2p_orphan_fallback_branch false "$G4_DETAIL"
fi

###############################################################################
# Compute reward
###############################################################################
P2P_OK=true
if [ "$P2P_SOS" -eq 0 ] || [ "$P2P_TU" -eq 0 ] || [ "$P2P_EP" -eq 0 ]; then
    P2P_OK=false
fi

REWARD=0
if [ "$P2P_OK" = true ]; then
    [ "$G1_PASS" = true ] && REWARD=$(awk "BEGIN{print $REWARD + 0.30}")
    [ "$G2_PASS" = true ] && REWARD=$(awk "BEGIN{print $REWARD + 0.20}")
    [ "$G3_PASS" = true ] && REWARD=$(awk "BEGIN{print $REWARD + 0.30}")
    [ "$G4_PASS" = true ] && REWARD=$(awk "BEGIN{print $REWARD + 0.20}")
fi

printf "%.4f\n" "$REWARD" > "$REWARD_FILE"
echo "FINAL REWARD: $(cat $REWARD_FILE)"
# ---- v042 upstream CI gates (auto-injected) ----
# v043 upstream gates: prelude(s) + per-gate execution.
(
    set +e
    # prelude 0
    echo 'c2V0ICtlOyBjZCAvd29ya3NwYWNlL3JlcG8gJiYgY29tbWFuZCAtdiBucHggPi9kZXYvbnVsbCAmJiBlY2hvIE9L' | base64 -d | bash 2>&1 | tail -2
) 2>/dev/null

run_v043_gate() {
    local id="$1" label="$2"; shift 2
    local cmd="$*"
    local rc out tail
    out=$(timeout 240 bash -c "$cmd" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        emit "$id" true ""
    else
        tail="${out: -180}"
        tail="${tail//\"/\'}"
        tail="${tail//$'\n'/ }"
        emit "$id" false "rc=$rc; $tail"
    fi
}
run_v043_gate p2p_upstream_523760b1 'tsc_noemit' 'cd /workspace/repo && cd /workspace/repo && timeout 90 npx tsc --noEmit -p tsconfig.app.json 2>&1 | tail -5; if grep -q '\''error TS'\'' /tmp/tsc.out 2>/dev/null; then exit 1; fi'
run_v043_gate p2p_upstream_cdf050a5 'npm_run_build' 'cd /workspace/repo && cd /workspace/repo && timeout 240 npm run build 2>&1 | tail -3'

# Recompute reward using v043 weights.
python3 - <<"V043_PY"
import json, os
WEIGHTS = {"t1_f2p_extract_pair_shot_id": 0.2, "t1_f2p_is_segment_video_task_field": 0.3, "t1_f2p_lightbox_receives_segment_context": 0.3, "t3_f2p_orphan_fallback_branch": 0.2}
P2P_GATING = ["p2p_segment_output_strip_intact", "p2p_task_utils_exports_intact", "p2p_enhance_prompt_default_unchanged"]
P2P_REGRESSION = ["p2p_upstream_523760b1", "p2p_upstream_cdf050a5"]
verdicts = {}
try:
    with open('/logs/verifier/gates.json') as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try:
                d = json.loads(line)
                gid = d.get('id')
                if gid: verdicts[gid] = bool(d.get('passed'))
            except Exception: pass
except FileNotFoundError: pass
hard_zero = False
for gid in P2P_GATING + P2P_REGRESSION:
    if not verdicts.get(gid, False):
        hard_zero = True; break
if hard_zero: reward = 0.0
else:
    reward = 0.0
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid, False): reward += w
    if reward > 1.0: reward = 1.0
os.makedirs('/logs/verifier', exist_ok=True)
with open('/logs/verifier/reward.txt', 'w') as f:
    f.write('%.4f\n' % reward)
print('V043_REWARD=%.4f' % reward)
V043_PY
# ---- v042 end upstream CI gates ----

exit 0