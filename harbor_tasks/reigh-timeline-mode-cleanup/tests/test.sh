#!/bin/bash
set +e

export PATH=/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH

REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
mkdir -p "$(dirname "$REWARD_FILE")" 2>/dev/null
chmod 777 "$(dirname "$REWARD_FILE")" 2>/dev/null
: > "$GATES_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    # escape quotes/backslashes in detail
    detail=$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

# Detect repo path
REPO=""
for candidate in /workspace/reigh /workspace/repo; do
    if [ -d "$candidate/src/tools/travel-between-images" ]; then
        REPO="$candidate"
        break
    fi
done
if [ -z "$REPO" ]; then
    REPO=$(find /workspace -maxdepth 4 -type d -name "travel-between-images" 2>/dev/null | head -1 | sed 's|/src/tools/travel-between-images||')
fi

echo "Using REPO=$REPO"

if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
    echo "FATAL: cannot find repo"
    emit p2p_essential_files_present false "repo not found"
    printf "%.4f\n" 0.0 > "$REWARD_FILE"
    exit 0
fi

SRC="$REPO/src"
TBI="$REPO/src/tools/travel-between-images/components"
TMC="$TBI/ShotImagesEditor/components/TimelineModeContent.tsx"
BARREL="$TBI/ShotImagesEditor/components/index.ts"
SHOT_EDITOR="$TBI/ShotImagesEditor.tsx"
TIMELINE="$TBI/Timeline.tsx"
TC_DIR="$TBI/Timeline"
# TimelineContainer location varies — search
TC=$(find "$TC_DIR" -name 'TimelineContainer.tsx' 2>/dev/null | head -1)
TC_TYPES=$(find "$TC_DIR" -path '*TimelineContainer*' -name 'types.ts' 2>/dev/null | head -1)

# ---------------------------------------------------------------------------
# P2P: essential files exist
# ---------------------------------------------------------------------------
P2P_OK=1
for f in "$SHOT_EDITOR" "$TIMELINE"; do
    if [ ! -f "$f" ]; then
        echo "P2P FAIL: $f missing"
        P2P_OK=0
    fi
done
if [ "$P2P_OK" = "1" ]; then
    emit p2p_essential_files_present true ""
else
    emit p2p_essential_files_present false "core file missing"
fi

# ---------------------------------------------------------------------------
# Gate t1_f2p_tmc_deleted (0.15)
# - TMC file gone
# - No code-level imports of TimelineModeContent anywhere in src
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t1_f2p_tmc_deleted ==="
TMC_GONE=0
[ ! -f "$TMC" ] && TMC_GONE=1

# Find any import statement referencing TimelineModeContent
IMPORT_REFS=$(grep -rE "(import|from).*TimelineModeContent" "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null \
    | grep -vE '^\s*(//|\*)')
# Also catch JSX tag usage
JSX_REFS=$(grep -rE '<TimelineModeContent[[:space:]/>]' "$SRC" --include='*.ts' --include='*.tsx' 2>/dev/null \
    | grep -vE '^\s*(//|\*)')

if [ "$TMC_GONE" = "1" ] && [ -z "$IMPORT_REFS" ] && [ -z "$JSX_REFS" ]; then
    echo "PASS"
    emit t1_f2p_tmc_deleted true ""
else
    echo "FAIL: TMC_GONE=$TMC_GONE"
    echo "imports: $IMPORT_REFS"
    echo "jsx: $JSX_REFS"
    emit t1_f2p_tmc_deleted false "tmc still present or referenced"
fi

# ---------------------------------------------------------------------------
# Gate t1_f2p_timeline_rendered_directly (0.15)
# Behavioral: ShotImagesEditor must
#   (a) import Timeline (any path ending in Timeline)
#   (b) contain a <Timeline ...> JSX tag
#   (c) NOT contain <TimelineModeContent
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t1_f2p_timeline_rendered_directly ==="
G=0
if [ -f "$SHOT_EDITOR" ]; then
    HAS_IMPORT=0
    # accept "import Timeline from './Timeline'" or "import { Timeline }" or with various paths
    if grep -qE "import[[:space:]]+(\{[[:space:]]*Timeline[[:space:]]*[,}]|Timeline[[:space:]]+from)" "$SHOT_EDITOR"; then
        HAS_IMPORT=1
    fi
    HAS_JSX=0
    if grep -qE '<Timeline[[:space:]>]' "$SHOT_EDITOR"; then
        HAS_JSX=1
    fi
    HAS_TMC_JSX=0
    if grep -qE '<TimelineModeContent' "$SHOT_EDITOR"; then
        HAS_TMC_JSX=1
    fi
    # Also require shotId being passed (the key remap ensures Timeline is properly wired)
    HAS_SHOTID=0
    if grep -qE 'shotId[[:space:]]*=[[:space:]]*\{' "$SHOT_EDITOR"; then
        HAS_SHOTID=1
    fi

    if [ "$HAS_IMPORT" = "1" ] && [ "$HAS_JSX" = "1" ] && [ "$HAS_TMC_JSX" = "0" ] && [ "$HAS_SHOTID" = "1" ]; then
        G=1
    fi
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t1_f2p_timeline_rendered_directly true ""
else
    echo "FAIL"
    emit t1_f2p_timeline_rendered_directly false "Timeline not directly rendered"
fi

# ---------------------------------------------------------------------------
# Gate t1_f2p_prop_remap_complete (0.15)
# Require frameSpacing remap AND at least 4 of the renamed handler props are wired
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t1_f2p_prop_remap_complete ==="
G=0
if [ -f "$SHOT_EDITOR" ] && ! grep -q '<TimelineModeContent' "$SHOT_EDITOR"; then
    HAS_FRAME_SPACING=0
    grep -qE 'frameSpacing[[:space:]]*=[[:space:]]*\{' "$SHOT_EDITOR" && HAS_FRAME_SPACING=1

    HANDLER_COUNT=0
    for p in onClearEnhancedPrompt onTimelineChange onPairClick onSegmentFrameCountChange onRegisterTrailingUpdater onDragStateChange; do
        if grep -qE "${p}[[:space:]]*=[[:space:]]*\{" "$SHOT_EDITOR"; then
            HANDLER_COUNT=$((HANDLER_COUNT + 1))
        fi
    done
    echo "frameSpacing=$HAS_FRAME_SPACING handlers=$HANDLER_COUNT"
    if [ "$HAS_FRAME_SPACING" = "1" ] && [ "$HANDLER_COUNT" -ge "4" ]; then
        G=1
    fi
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t1_f2p_prop_remap_complete true ""
else
    echo "FAIL"
    emit t1_f2p_prop_remap_complete false "prop remap missing"
fi

# ---------------------------------------------------------------------------
# Gate t1_f2p_unpositioned_helper_inlined (0.10)
# Require: unpositionedGenerationsCount conditional + onClick={onOpenUnpositionedPane}
#   appearing in proximity (within 30 lines)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t1_f2p_unpositioned_helper_inlined ==="
G=0
if [ -f "$SHOT_EDITOR" ]; then
    # Look for conditional render with count > 0 and onClick handler near each other
    if awk '
        /unpositionedGenerationsCount[[:space:]]*>[[:space:]]*0/ { found_cond = NR }
        /onClick[[:space:]]*=[[:space:]]*\{[[:space:]]*onOpenUnpositionedPane/ {
            if (found_cond > 0 && NR - found_cond <= 30) { print "MATCH"; exit 0 }
        }
        END { exit 1 }
    ' "$SHOT_EDITOR" 2>/dev/null | grep -q MATCH; then
        # Also require visible button text
        if grep -qE 'View[[:space:]]*&[[:space:]]*Position|unpositioned generation' "$SHOT_EDITOR"; then
            G=1
        fi
    fi
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t1_f2p_unpositioned_helper_inlined true ""
else
    echo "FAIL"
    emit t1_f2p_unpositioned_helper_inlined false "helper not inlined with conditional+onClick"
fi

# ---------------------------------------------------------------------------
# Gate t1_f2p_barrel_cleaned (0.10)
# - barrel exists
# - has no TimelineModeContent reference
# - still re-exports BatchModeContent (proves it wasn't just deleted to game it)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t1_f2p_barrel_cleaned ==="
G=0
if [ -f "$BARREL" ]; then
    if ! grep -q 'TimelineModeContent' "$BARREL" && grep -q 'BatchModeContent' "$BARREL"; then
        G=1
    fi
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t1_f2p_barrel_cleaned true ""
else
    echo "FAIL"
    emit t1_f2p_barrel_cleaned false "barrel not properly scrubbed"
fi

# ---------------------------------------------------------------------------
# Gate t2_f2p_dead_constant_removed (0.10)
# EMPTY_ENHANCED_PROMPTS gone from Timeline.tsx, AND Timeline.tsx still exports a Timeline component
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t2_f2p_dead_constant_removed ==="
G=0
if [ -f "$TIMELINE" ] && ! grep -q 'EMPTY_ENHANCED_PROMPTS' "$TIMELINE"; then
    # ensure Timeline component still defined
    if grep -qE '(export default|export const Timeline|export function Timeline|const Timeline[[:space:]]*[:=]|function Timeline[[:space:]]*\()' "$TIMELINE"; then
        G=1
    fi
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t2_f2p_dead_constant_removed true ""
else
    echo "FAIL"
    emit t2_f2p_dead_constant_removed false "EMPTY_ENHANCED_PROMPTS still present or Timeline export gone"
fi

# ---------------------------------------------------------------------------
# Gate t2_f2p_enhancedprompts_purged (0.15)
# enhancedPrompts gone from Timeline.tsx AND from TimelineContainer (types or impl)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t2_f2p_enhancedprompts_purged ==="
G=0
TL_CLEAN=0
TC_CLEAN=0
if [ -f "$TIMELINE" ] && ! grep -q 'enhancedPrompts' "$TIMELINE"; then
    # also ensure file still has a Timeline component (didn't gut the file)
    if grep -qE '(export default|Timeline)' "$TIMELINE"; then
        TL_CLEAN=1
    fi
fi
# Check TimelineContainer chain - either types.ts or TimelineContainer.tsx
if [ -n "$TC_TYPES" ] && [ -f "$TC_TYPES" ]; then
    grep -q 'enhancedPrompts' "$TC_TYPES" || TC_CLEAN=1
fi
if [ -n "$TC" ] && [ -f "$TC" ]; then
    if ! grep -q 'enhancedPrompts' "$TC"; then
        # TC clean — if types also clean, keep; else still ok if TC is clean
        TC_CLEAN=1
    fi
fi
# If neither TC file found, only require Timeline.tsx clean
if [ -z "$TC" ] && [ -z "$TC_TYPES" ]; then
    TC_CLEAN=1
fi

if [ "$TL_CLEAN" = "1" ] && [ "$TC_CLEAN" = "1" ]; then
    G=1
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t2_f2p_enhancedprompts_purged true ""
else
    echo "FAIL: TL_CLEAN=$TL_CLEAN TC_CLEAN=$TC_CLEAN"
    emit t2_f2p_enhancedprompts_purged false "enhancedPrompts not fully purged"
fi

# ---------------------------------------------------------------------------
# Gate t2_f2p_propHookData_removed (0.10)
# ---------------------------------------------------------------------------
echo ""
echo "=== Gate: t2_f2p_propHookData_removed ==="
G=0
if [ -f "$TIMELINE" ] && ! grep -qE '\bpropHookData\b' "$TIMELINE"; then
    # ensure the file still has substance
    LINES=$(wc -l < "$TIMELINE")
    if [ "$LINES" -ge "20" ]; then
        G=1
    fi
fi
if [ "$G" = "1" ]; then
    echo "PASS"
    emit t2_f2p_propHookData_removed true ""
else
    echo "FAIL"
    emit t2_f2p_propHookData_removed false "propHookData still present or Timeline.tsx gutted"
fi

# ---------------------------------------------------------------------------
# Compute reward
# ---------------------------------------------------------------------------
REWARD=$(python3 -c "
import json
total = 0.0
weights = {
    't1_f2p_tmc_deleted': 0.15,
    't1_f2p_timeline_rendered_directly': 0.15,
    't1_f2p_prop_remap_complete': 0.15,
    't1_f2p_unpositioned_helper_inlined': 0.10,
    't1_f2p_barrel_cleaned': 0.10,
    't2_f2p_dead_constant_removed': 0.10,
    't2_f2p_enhancedprompts_purged': 0.15,
    't2_f2p_propHookData_removed': 0.10,
}
with open('$GATES_FILE') as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try:
            g = json.loads(line)
        except: continue
        gid = g['id']
        if g['passed'] and gid in weights:
            total += weights[gid]
print(f'{total:.4f}')
")

echo ""
echo "=== FINAL REWARD: $REWARD ==="
printf "%.4f\n" "$REWARD" > "$REWARD_FILE"
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
WEIGHTS = {"t1_f2p_barrel_cleaned": 0.1, "t1_f2p_prop_remap_complete": 0.15, "t1_f2p_timeline_rendered_directly": 0.15, "t1_f2p_tmc_deleted": 0.15, "t1_f2p_unpositioned_helper_inlined": 0.1, "t2_f2p_dead_constant_removed": 0.1, "t2_f2p_enhancedprompts_purged": 0.15, "t2_f2p_propHookData_removed": 0.1}
P2P_REGRESSION = ["p2p_essential_files_present"]
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
# P2P failures are diagnostics/penalty inputs; they diagnostic/penalty only.
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

# >>> auto_gate_bridge >>>
# Auto-generated by scripts/fix_emit_gates.py.
# Bridges manifest gates → /logs/verifier/gates.json so the canonical
# F2P-coverage formula matches the legacy reward.txt for tasks that were
# scored only via inline `add_reward` style. Idempotent.
#
# Semantics:
#   F2P gate without an explicit emit → proportionally pass `round(N*L)`
#     gates (where N = total F2P gates, L = legacy reward.txt), so the
#     canonical f2p_pass_rate reproduces the legacy reward.
#   P2P_REGRESSION without an explicit emit → passed: true (informational,
#     matches pre-canonical bash where unemitted P2P had no effect).
#
# After bridging, reward.txt is left as the legacy value. The host-side
# canonicalize_reward_from_gates() (per_turn_replay.py, oracle_replay.py)
# reads the now-complete gates.json and recomputes via the unified formula.
python3 - <<'AUTO_GATE_BRIDGE_PYEOF'
import json, os, sys
from pathlib import Path

LOGS = Path("/logs/verifier")
gates_path = LOGS / "gates.json"
reward_path = LOGS / "reward.txt"

# Locate the manifest at runtime. Harbor mounts the harbor task's tests/
# dir at /tests so the manifest is /tests/test_manifest.yaml.
manifest_candidates = [
    Path("/tests/test_manifest.yaml"),
    Path(os.environ.get("TEST_MANIFEST", "")),
]
manifest_path = next((p for p in manifest_candidates if p and p.is_file()), None)
if manifest_path is None:
    sys.exit(0)

try:
    import yaml
    raw = yaml.safe_load(manifest_path.read_text())
except Exception:
    sys.exit(0)

gates = (raw or {}).get("gates") or []
if not gates:
    sys.exit(0)

try:
    legacy_reward = float(reward_path.read_text().strip())
except Exception:
    legacy_reward = 0.0

existing_ids = set()
try:
    txt = gates_path.read_text().strip()
    if txt.startswith("[") or txt.startswith("{"):
        d = json.loads(txt)
        if isinstance(d, dict) and "gates" in d:
            for g in d["gates"]:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
        elif isinstance(d, list):
            for g in d:
                if isinstance(g, dict) and g.get("id"):
                    existing_ids.add(g["id"])
    else:
        for line in txt.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("id"):
                    existing_ids.add(obj["id"])
            except Exception:
                pass
except FileNotFoundError:
    pass

all_gate_ids = []
f2p_missing_ids = []
p2p_missing_ids = []
for g in gates:
    if not isinstance(g, dict):
        continue
    gid = g.get("id")
    kind = g.get("kind", "F2P")
    if not gid:
        continue
    all_gate_ids.append((gid, kind))
    if gid in existing_ids:
        continue
    if kind == "F2P":
        f2p_missing_ids.append(gid)
    elif kind.startswith("P2P"):  # P2P_REGRESSION, P2P, deprecated kinds
        p2p_missing_ids.append(gid)

f2p_total = sum(1 for gid, kind in all_gate_ids if kind == "F2P")
target_passes = int(round(legacy_reward * f2p_total))

explicit_pass = 0
try:
    with gates_path.open() as _f:
        for line in _f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") and d.get("passed"):
                for (gid, kind) in all_gate_ids:
                    if gid == d["id"] and kind == "F2P":
                        explicit_pass += 1
                        break
except Exception:
    pass

bridge_passes = max(0, target_passes - explicit_pass)
bridge_passes = min(bridge_passes, len(f2p_missing_ids))

to_append = []
for i, gid in enumerate(f2p_missing_ids):
    passed = bool(i < bridge_passes)
    detail = "auto-bridge: F2P proportional (target=%d/%d, legacy=%.3f)" % (
        target_passes, f2p_total, legacy_reward,
    )
    to_append.append({"id": gid, "passed": passed, "detail": detail})
for gid in p2p_missing_ids:
    to_append.append({
        "id": gid,
        "passed": True,
        "detail": "auto-bridge: P2P default-pass (no explicit emit)",
    })

if to_append:
    LOGS.mkdir(parents=True, exist_ok=True)
    with gates_path.open("a") as _f:
        for obj in to_append:
            _f.write(json.dumps(obj) + "\n")
AUTO_GATE_BRIDGE_PYEOF
# <<< auto_gate_bridge <<<
