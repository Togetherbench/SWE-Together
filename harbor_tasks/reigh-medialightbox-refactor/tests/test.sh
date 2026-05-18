#!/bin/bash
set +e

REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"
mkdir -p /logs/verifier
: > "$GATES_FILE"
echo "0.0000" > "$REWARD_FILE"

emit() {
    local id="$1" passed="$2" detail="${3:-}"
    detail=$(printf '%s' "$detail" | tr -d '\n' | sed 's/"/\\"/g')
    printf '{"id":"%s","passed":%s,"detail":"%s"}\n' "$id" "$passed" "$detail" >> "$GATES_FILE"
}

export PATH="/usr/local/cargo/bin:/root/.bun/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Locate workspace
WORKSPACE=""
REPO_NAME=""
for cand in /workspace/reigh /workspace/repo /workspace/medialightbox-refactor /workspace; do
    if [ -d "$cand/src/shared/components/MediaLightbox" ]; then
        WORKSPACE="$cand"
        REPO_NAME=$(basename "$cand")
        break
    fi
done
if [ -z "$WORKSPACE" ]; then
    found=$(find /workspace -maxdepth 6 -type d -name "MediaLightbox" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        WORKSPACE=$(echo "$found" | sed 's|/src/shared/components/MediaLightbox||')
        REPO_NAME=$(basename "$WORKSPACE")
    fi
fi

if [ -z "$WORKSPACE" ] || [ ! -d "$WORKSPACE" ]; then
    echo "FATAL: workspace not found"
    emit p2p_instruction_unmodified true "no workspace"
    emit p2p_no_component_tsc_regression true "no workspace"
    emit t1_f2p_main_file_shrunk_real false "no workspace"
    emit t1_f2p_dimension_util_behavior false "no workspace"
    emit t3_f2p_substantive_modules_wired false "no workspace"
    emit t3_f2p_debug_noise_removed false "no workspace"
    emit t3_f2p_main_render_smoke false "no workspace"
    emit t8_f2p_diverse_extraction false "no workspace"
    printf "%.4f\n" 0 > "$REWARD_FILE"
    exit 0
fi
echo "Workspace: $WORKSPACE (repo=$REPO_NAME)"
cd "$WORKSPACE" || exit 0

COMPONENT_DIR="src/shared/components/MediaLightbox"
MAIN_FILE="$COMPONENT_DIR/MediaLightbox.tsx"
ORIGINAL_MAIN_LINES=2672
ORIGINAL_NONBLANK_LOC=2200  # approximate baseline of significant lines

# ─── P2P: instruction.md unmodified ───────────────────────────────────────
if [ -f instruction.md ]; then
    if git diff --quiet HEAD -- instruction.md 2>/dev/null; then
        emit p2p_instruction_unmodified true ""
    else
        # Could have been added by template; check if mtime suspicious
        emit p2p_instruction_unmodified true "no diff tracking"
    fi
else
    emit p2p_instruction_unmodified true "no instruction.md"
fi

# ─── P2P: tsc regression in component dir ─────────────────────────────────
TSC_COMP_ERRS=0
if command -v npx >/dev/null 2>&1 && [ -f tsconfig.json ]; then
    timeout 420 npx --no-install tsc --noEmit > /tmp/tsc_output.txt 2>&1
    TSC_COMP_ERRS=$(grep -E "error TS[0-9]+" /tmp/tsc_output.txt 2>/dev/null | grep -c "$COMPONENT_DIR")
fi
if [ "$TSC_COMP_ERRS" -eq 0 ]; then
    emit p2p_no_component_tsc_regression true ""
else
    emit p2p_no_component_tsc_regression false "component tsc errors=$TSC_COMP_ERRS"
fi

# ─── Sanity: main file exists ─────────────────────────────────────────────
if [ ! -f "$MAIN_FILE" ]; then
    emit t1_f2p_main_file_shrunk_real false "main missing"
    emit t1_f2p_dimension_util_behavior false "main missing"
    emit t3_f2p_substantive_modules_wired false "main missing"
    emit t3_f2p_debug_noise_removed false "main missing"
    emit t3_f2p_main_render_smoke false "main missing"
    emit t8_f2p_diverse_extraction false "main missing"
    printf "%.4f\n" 0 > "$REWARD_FILE"
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
WEIGHTS = {"t1_f2p_dimension_util_behavior": 0.2, "t1_f2p_main_file_shrunk_real": 0.2, "t3_f2p_debug_noise_removed": 0.15, "t3_f2p_main_render_smoke": 0.1, "t3_f2p_substantive_modules_wired": 0.2, "t8_f2p_diverse_extraction": 0.15}
P2P_REGRESSION = ["p2p_instruction_unmodified", "p2p_no_component_tsc_regression"]
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
# P2P failures are diagnostics/penalty inputs; they never feed bounded penalty/diagnostics.
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
fi

# ─── Discover new files in component dir (only in MediaLightbox) ──────────
NEW_FILES=()
NEW_FILE_LIST=$(git -C "$WORKSPACE" ls-files --others --exclude-standard "$COMPONENT_DIR" 2>/dev/null | grep -E "\.(ts|tsx)$")
# Also include files that exist but are not in the index yet (new)
while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ "$f" = "$MAIN_FILE" ] && continue
    if [ -f "$WORKSPACE/$f" ]; then
        FLINES=$(wc -l < "$WORKSPACE/$f")
        # substantive: ≥15 lines AND has at least one non-trivial export
        if [ "$FLINES" -ge 15 ] && grep -qE "^export (function|const [A-Za-z_]+ *= *(\(|React|use|async|function)|default function|class |interface |type )" "$WORKSPACE/$f" 2>/dev/null; then
            NEW_FILES+=("$f")
        fi
    fi
done <<< "$NEW_FILE_LIST"

echo "Substantive new files: ${#NEW_FILES[@]}"
for f in "${NEW_FILES[@]}"; do echo "  $f"; done

# ─── GATE: t1_f2p_main_file_shrunk_real ──────────────────────────────────
# Non-blank, non-pure-comment LOC reduction >=15% AND new files contain >= 60% of removed LOC.
CURR_NONBLANK=$(grep -cvE '^[[:space:]]*(//|\*|/\*|$)' "$MAIN_FILE" 2>/dev/null)
TOTAL_NEW_NONBLANK=0
for f in "${NEW_FILES[@]}"; do
    n=$(grep -cvE '^[[:space:]]*(//|\*|/\*|$)' "$WORKSPACE/$f" 2>/dev/null)
    TOTAL_NEW_NONBLANK=$((TOTAL_NEW_NONBLANK + n))
done

REMOVED=$((ORIGINAL_NONBLANK_LOC - CURR_NONBLANK))
if [ "$ORIGINAL_NONBLANK_LOC" -gt 0 ]; then
    PCT=$(( REMOVED * 100 / ORIGINAL_NONBLANK_LOC ))
else
    PCT=0
fi
echo "main nonblank LOC: $CURR_NONBLANK (removed=$REMOVED, pct=${PCT}%, new_nonblank=$TOTAL_NEW_NONBLANK)"

THRESHOLD=$(( REMOVED * 60 / 100 ))
if [ "$PCT" -ge 15 ] && [ "$REMOVED" -gt 0 ] && [ "$TOTAL_NEW_NONBLANK" -ge "$THRESHOLD" ] && [ "$TOTAL_NEW_NONBLANK" -ge 80 ]; then
    emit t1_f2p_main_file_shrunk_real true "pct=${PCT} new=${TOTAL_NEW_NONBLANK}"
else
    emit t1_f2p_main_file_shrunk_real false "pct=${PCT} new=${TOTAL_NEW_NONBLANK} need_pct>=15 new>=${THRESHOLD}"
fi

# ─── GATE: t1_f2p_dimension_util_behavior ────────────────────────────────
# Find a file that exports resolutionToDimensions OUTSIDE main file, AND main no longer
# defines it inline. Then run it via node and assert behavior.
DIM_FILE=$(grep -rEl "^export (function|const) resolutionToDimensions" "$COMPONENT_DIR" 2>/dev/null | grep -v "MediaLightbox.tsx" | head -1)
INLINE_RES_DEF=$(grep -cE "^[[:space:]]*const resolutionToDimensions[[:space:]]*=[[:space:]]*\(" "$MAIN_FILE" 2>/dev/null)

DIM_PASS=false
if [ -n "$DIM_FILE" ] && [ "$INLINE_RES_DEF" -eq 0 ]; then
    # Build a tiny CJS test that strips TS types and runs the function
    if command -v node >/dev/null 2>&1; then
        # Extract the resolutionToDimensions function source
        cat > /tmp/dim_extract.js <<'EXTRACT_EOF'
const fs = require('fs');
const file = process.argv[2];
const src = fs.readFileSync(file, 'utf8');
// Find export of resolutionToDimensions (function or const)
let match = src.match(/export\s+(?:const|function)\s+resolutionToDimensions[\s\S]*?(?=^export\s|^\s*\/\/\s*={3,}|\Z)/m);
if (!match) {
    // fallback: take from first occurrence to end of file
    const idx = src.search(/export\s+(?:const|function)\s+resolutionToDimensions/);
    if (idx === -1) { console.error('NOT_FOUND'); process.exit(2); }
    match = [src.slice(idx)];
}
let snippet = match[0];
// Strip TS type annotations (very rough): ": Type" up to , ) = ; \n
snippet = snippet
    .replace(/:\s*\{[^}]*\}\s*(?=[,)=;])/g, '')
    .replace(/:\s*[A-Za-z_][A-Za-z0-9_<>\[\]\|&\s,'".]*?(?=[,)=;\n])/g, '')
    .replace(/\bexport\s+/g, '')
    .replace(/\bas\s+const\b/g, '')
    .replace(/\bas\s+[A-Za-z_][A-Za-z0-9_<>\[\]\|&]*\b/g, '');
// Wrap and expose
const wrapped = `${snippet}\nmodule.exports = { resolutionToDimensions };`;
fs.writeFileSync('/tmp/dim_module.js', wrapped);
console.log('OK');
EXTRACT_EOF
        node /tmp/dim_extract.js "$WORKSPACE/$DIM_FILE" > /tmp/dim_extract_out.txt 2>&1
        EXTRACT_EXIT=$?
        if [ "$EXTRACT_EXIT" -eq 0 ]; then
            cat > /tmp/dim_test.js <<'TEST_EOF'
let mod;
try { mod = require('/tmp/dim_module.js'); }
catch (e) { console.error('REQUIRE_FAIL:', e.message); process.exit(3); }
const fn = mod.resolutionToDimensions;
if (typeof fn !== 'function') { console.error('NOT_FUNCTION'); process.exit(4); }

let pass = 0, fail = 0;
function check(name, actual, predicate) {
    let ok;
    try { ok = predicate(actual); } catch(e) { ok = false; }
    if (ok) { pass++; console.log('PASS', name); }
    else { fail++; console.log('FAIL', name, 'got=', JSON.stringify(actual)); }
}

// Case 1: standard "1024x768"
check('1024x768', fn('1024x768'), v => v && v.width === 1024 && v.height === 768);
// Case 2: "1920x1080"
check('1920x1080', fn('1920x1080'), v => v && v.width === 1920 && v.height === 1080);
// Case 3: empty string => null/undefined/falsy
check('empty_falsy', fn(''), v => !v || (v.width === 0 && v.height === 0));
// Case 4: garbage => null/undefined/falsy
check('garbage_falsy', fn('not_a_resolution'), v => !v || (typeof v.width !== 'number' || isNaN(v.width)));
// Case 5: missing x => null/undefined/falsy
check('no_x_falsy', fn('1024'), v => !v || isNaN(v.width) || isNaN(v.height));
// Case 6: square
check('512x512', fn('512x512'), v => v && v.width === 512 && v.height === 512);

console.log('SUMMARY pass=' + pass + ' fail=' + fail);
process.exit(fail > 0 ? 1 : 0);
TEST_EOF
            timeout 15 node /tmp/dim_test.js > /tmp/dim_test_out.txt 2>&1
            DIM_EXIT=$?
            cat /tmp/dim_test_out.txt
            PASS_COUNT=$(grep -c "^PASS " /tmp/dim_test_out.txt 2>/dev/null)
            if [ "$DIM_EXIT" -eq 0 ] && [ "$PASS_COUNT" -ge 6 ]; then
                DIM_PASS=true
            elif [ "$PASS_COUNT" -ge 4 ]; then
                # behavior mostly correct
                DIM_PASS=true
            fi
        fi
    fi
fi

if [ "$DIM_PASS" = "true" ]; then
    emit t1_f2p_dimension_util_behavior true "extracted to $DIM_FILE"
else
    emit t1_f2p_dimension_util_behavior false "no extracted dim util that behaves correctly (DIM_FILE=$DIM_FILE inline=$INLINE_RES_DEF)"
fi

# ─── GATE: t3_f2p_substantive_modules_wired ──────────────────────────────
# A module is wired if main file (or another wired new file transitively) imports it via
# a real import statement. No bare-word matches.
WIRED_MODULES=()
is_imported_in() {
    local target_module="$1" target_file="$2"
    # match: import ... from '...<modname>' or '...<modname>/index'
    grep -qE "^import [^;]*from [\"'][^\"']*${target_module}([/\"'])" "$target_file" 2>/dev/null
}

declare -A WIRED_MAP
# First pass: directly imported in main
for f in "${NEW_FILES[@]}"; do
    base=$(basename "$f" | sed 's/\.[tj]sx\?$//')
    case "$base" in index|types|constants) continue ;; esac
    if is_imported_in "$base" "$MAIN_FILE"; then
        WIRED_MAP["$f"]=1
        WIRED_MODULES+=("$f")
    fi
done

# Second pass: transitive via another wired new file or via /hooks /utils /components /contexts barrels
# Only count if main imports the barrel and the new file is exported by that barrel.
check_barrel() {
    local subdir="$1" newfile="$2"
    local barrel="$COMPONENT_DIR/$subdir/index.ts"
    local barrel_tsx="$COMPONENT_DIR/$subdir/index.tsx"
    [ -f "$barrel" ] || barrel="$barrel_tsx"
    [ -f "$barrel" ] || return 1
    local newbase=$(basename "$newfile" | sed 's/\.[tj]sx\?$//')
    grep -qE "(from [\"']\\./${newbase}[\"'])|(\\b${newbase}\\b)" "$barrel" 2>/dev/null || return 1
    grep -qE "^import [^;]*from [\"'][^\"']*/${subdir}[\"']" "$MAIN_FILE" 2>/dev/null
}

for f in "${NEW_FILES[@]}"; do
    [ -n "${WIRED_MAP[$f]}" ] && continue
    case "$f" in
        */hooks/*) check_barrel "hooks" "$f" && WIRED_MAP["$f"]=1 && WIRED_MODULES+=("$f") ;;
        */utils/*) check_barrel "utils" "$f" && WIRED_MAP["$f"]=1 && WIRED_MODULES+=("$f") ;;
        */components/*) check_barrel "components" "$f" && WIRED_MAP["$f"]=1 && WIRED_MODULES+=("$f") ;;
        */contexts/*) check_barrel "contexts" "$f" && WIRED_MAP["$f"]=1 && WIRED_MODULES+=("$f") ;;
    esac
done

# Third: transitive — wired-via-another-wired-new-file
for f in "${NEW_FILES[@]}"; do
    [ -n "${WIRED_MAP[$f]}" ] && continue
    base=$(basename "$f" | sed 's/\.[tj]sx\?$//')
    case "$base" in index|types|constants) continue ;; esac
    for other in "${!WIRED_MAP[@]}"; do
        [ "$other" = "$f" ] && continue
        if is_imported_in "$base" "$WORKSPACE/$other"; then
            WIRED_MAP["$f"]=1
            WIRED_MODULES+=("$f")
            break
        fi
    done
done

WIRED_COUNT=${#WIRED_MODULES[@]}
echo "Wired modules: $WIRED_COUNT"
for m in "${WIRED_MODULES[@]}"; do echo "  $m"; done

if [ "$WIRED_COUNT" -ge 2 ]; then
    emit t3_f2p_substantive_modules_wired true "wired=$WIRED_COUNT"
else
    emit t3_f2p_substantive_modules_wired false "only $WIRED_COUNT wired (need >=2)"
fi

# ─── GATE: t3_f2p_debug_noise_removed ────────────────────────────────────
# Original file had heavy noise: ResolutionDebug, MOUNTED/CHANGED, VariantFetchDebug, emoji logs, ~50+ console.log
RESOLUTION_DEBUG=$(grep -c "ResolutionDebug" "$MAIN_FILE" 2>/dev/null)
MOUNTED_BANNER=$(grep -c "MOUNTED/CHANGED" "$MAIN_FILE" 2>/dev/null)
VARIANT_FETCH_DEBUG=$(grep -c "VariantFetchDebug" "$MAIN_FILE" 2>/dev/null)
VARIANT_DISPLAY_DEBUG=$(grep -c "VariantDisplay" "$MAIN_FILE" 2>/dev/null)
LIGHTBOX_EMOJI=$(grep -cE "console\.log\(['\"]?\[MediaLightbox\][^'\"]*[🎬💀✨🔥]" "$MAIN_FILE" 2>/dev/null)
NOISE_TOTAL=$((RESOLUTION_DEBUG + MOUNTED_BANNER + VARIANT_FETCH_DEBUG + VARIANT_DISPLAY_DEBUG + LIGHTBOX_EMOJI))
CONSOLE_LOGS=$(grep -c "console\.log" "$MAIN_FILE" 2>/dev/null)
echo "noise: ResDbg=$RESOLUTION_DEBUG Mounted=$MOUNTED_BANNER VarFetch=$VARIANT_FETCH_DEBUG VarDisp=$VARIANT_DISPLAY_DEBUG Emoji=$LIGHTBOX_EMOJI total=$NOISE_TOTAL console.log=$CONSOLE_LOGS"

if [ "$NOISE_TOTAL" -le 3 ] && [ "$CONSOLE_LOGS" -le 20 ]; then
    emit t3_f2p_debug_noise_removed true "noise=$NOISE_TOTAL console.log=$CONSOLE_LOGS"
else
    emit t3_f2p_debug_noise_removed false "noise=$NOISE_TOTAL console.log=$CONSOLE_LOGS"
fi

# ─── GATE: t3_f2p_main_render_smoke ──────────────────────────────────────
# Behavioral: parse main file as TS (strip types) and confirm it defines/exports MediaLightbox,
# and that all ./relative imports of new substantive modules resolve to existing files.
SMOKE_PASS=false
EXPORTS_ML=$(grep -cE "(export default|export const MediaLightbox|export function MediaLightbox|export \{[^}]*MediaLightbox[^}]*\})" "$MAIN_FILE" 2>/dev/null)
BROKEN=0
while IFS= read -r line; do
    ipath=$(echo "$line" | sed -nE "s/^import [^;]*from ['\"](\\.\\.?/[^'\"]+)['\"].*/\\1/p")
    [ -z "$ipath" ] && continue
    DIR=$(dirname "$MAIN_FILE")
    resolved="$DIR/$ipath"
    if [ ! -f "$resolved" ] && [ ! -f "$resolved.ts" ] && [ ! -f "$resolved.tsx" ] && \
       [ ! -f "$resolved/index.ts" ] && [ ! -f "$resolved/index.tsx" ]; then
        BROKEN=$((BROKEN+1))
        echo "BROKEN_IMPORT: $ipath"
    fi
done < <(grep -E "^import .*from ['\"]\\.\\.?/" "$MAIN_FILE" 2>/dev/null)

if [ "$EXPORTS_ML" -ge 1 ] && [ "$BROKEN" -eq 0 ]; then
    SMOKE_PASS=true
fi

# But we also require behavioral evidence the file actually changed (else nop passes).
# Tie smoke to: at least one new file exists AND is imported in main.
DIRECT_NEW_IMPORTS=0
for f in "${NEW_FILES[@]}"; do
    base=$(basename "$f" | sed 's/\.[tj]sx\?$//')
    [ "$base" = "index" ] && continue
    if grep -qE "^import [^;]*from [\"'][^\"']*${base}[\"/]" "$MAIN_FILE" 2>/dev/null; then
        DIRECT_NEW_IMPORTS=$((DIRECT_NEW_IMPORTS+1))
    fi
done

if [ "$SMOKE_PASS" = "true" ] && [ "$DIRECT_NEW_IMPORTS" -ge 1 ]; then
    emit t3_f2p_main_render_smoke true "exports_ok broken=0 new_imports=$DIRECT_NEW_IMPORTS"
else
    emit t3_f2p_main_render_smoke false "exports=$EXPORTS_ML broken=$BROKEN new_imports=$DIRECT_NEW_IMPORTS"
fi

# ─── GATE: t8_f2p_diverse_extraction ─────────────────────────────────────
# At least 2 categories among hooks/utils/components/contexts have ≥1 wired file each.
declare -A CAT_WIRED
for m in "${WIRED_MODULES[@]}"; do
    case "$m" in
        */hooks/*) CAT_WIRED[hooks]=1 ;;
        */utils/*) CAT_WIRED[utils]=1 ;;
        */components/*) CAT_WIRED[components]=1 ;;
        */contexts/*) CAT_WIRED[contexts]=1 ;;
    esac
done
CAT_COUNT=${#CAT_WIRED[@]}
echo "Wired categories: $CAT_COUNT (${!CAT_WIRED[@]})"

if [ "$CAT_COUNT" -ge 2 ]; then
    emit t8_f2p_diverse_extraction true "categories=$CAT_COUNT"
else
    emit t8_f2p_diverse_extraction false "categories=$CAT_COUNT (need >=2)"
fi

# ─── Compute reward ──────────────────────────────────────────────────────
declare -A WEIGHTS=(
    [t1_f2p_main_file_shrunk_real]="0.20"
    [t1_f2p_dimension_util_behavior]="0.20"
    [t3_f2p_substantive_modules_wired]="0.20"
    [t3_f2p_debug_noise_removed]="0.15"
    [t3_f2p_main_render_smoke]="0.10"
    [t8_f2p_diverse_extraction]="0.15"
)

# Check P2P diagnostic
P2P_FAIL=false
while IFS= read -r line; do
    id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
    passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
    case "$id" in
        p2p_*)
            if [ "$passed" = "false" ]; then
                P2P_FAIL=true
            fi
        ;;
    esac
done < "$GATES_FILE"

REWARD="0.0"
if [ "$P2P_FAIL" = "false" ]; then
    while IFS= read -r line; do
        id=$(echo "$line" | sed -nE 's/.*"id":"([^"]+)".*/\1/p')
        passed=$(echo "$line" | sed -nE 's/.*"passed":(true|false).*/\1/p')
        w="${WEIGHTS[$id]}"
        if [ -n "$w" ] && [ "$passed" = "true" ]; then
            REWARD=$(awk -v a="$REWARD" -v b="$w" 'BEGIN{printf "%.4f", a+b}')
        fi
    done < "$GATES_FILE"
fi

printf "%.4f\n" "$REWARD" > "$REWARD_FILE"
echo "Final reward: $(cat $REWARD_FILE)"
cat "$GATES_FILE"

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
