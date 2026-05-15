#!/usr/bin/env bash
# Verifier — gemini-voyager snow effect feature.
# Behavioral structural gates evaluated via python3 regex against the patched
# repo. Each gate writes a JSON verdict to /logs/verifier/gates.json; a
# weighted-replace reward is then computed in [0, 1].
#
# Pattern reference: harbor_tasks/amytis-task-103a94/tests/test.sh.
# Replaces the v0.4.3 SWE-rebench stub which fell back to "overall pass rate"
# of an empty test set, scoring ~1.0 on every trial regardless of changes.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO=/workspace/repo
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

# All gates implemented as python3 inline regex against file contents — no
# language-runtime dependency, deterministic, fast.

run_gate_py() {
    # $1 = gate id, $2 = python3 snippet that prints "PASS" or "FAIL: ..."
    # Returns the verdict ("true" or "false") on stdout. Diagnostic goes to
    # stderr so $(...) capture only picks up the verdict.
    local gid="$1"
    local snippet="$2"
    local out
    out=$(python3 -c "$snippet" 2>&1)
    echo "[gate $gid] $out" >&2
    [[ "$out" == "PASS"* ]] && echo true || echo false
}

# ──────────────────────────────────────────────────────────────────────────────
# F2P_STORAGE_KEY (0.15): src/core/types/common.ts adds the snow-effect storage
# key. We accept the canonical literal 'gvSnowEffect' OR any new key whose name
# contains both 'snow' and 'gv' (so renames like GV_SNOW_EFFECT_KEY still pass).
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=$(run_gate_py F2P_STORAGE_KEY '
import re, sys, os
p = "src/core/types/common.ts"
if not os.path.exists(p):
    print("FAIL: common.ts missing"); sys.exit(0)
s = open(p).read()
# Find the StorageKeys object and check it has a snow-related entry
m = re.search(r"StorageKeys\s*=\s*\{([^}]*)\}", s, re.S)
body = m.group(1) if m else s
literal = bool(re.search(r"[\x27\x22]gvSnowEffect[\x27\x22]", body))
keyish = bool(re.search(r"GV_SNOW[A-Z_]*\s*:", body, re.I)) or literal
print("PASS" if (literal or keyish) else f"FAIL: literal={literal} keyish={keyish}")
')

# ──────────────────────────────────────────────────────────────────────────────
# F2P_MODULE_EXISTS (0.25): src/pages/content/snowEffect/index.ts exists and:
#   - exports startSnowEffect (function or const arrow)
#   - creates a <canvas> element (document.createElement("canvas") OR a literal
#     canvas tag-string in innerHTML)
#   - configures pointer-events:none and position:fixed (in any quoting style)
#   - uses requestAnimationFrame (the rAF loop)
#   - reads a snow-related storage key
# Behavioral: doesn't pin variable names; rejects empty stubs.
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=$(run_gate_py F2P_MODULE_EXISTS '
import re, os, sys
p = "src/pages/content/snowEffect/index.ts"
if not os.path.exists(p):
    # Accept .tsx as well
    if os.path.exists("src/pages/content/snowEffect/index.tsx"):
        p = "src/pages/content/snowEffect/index.tsx"
    else:
        print("FAIL: snowEffect/index.{ts,tsx} missing"); sys.exit(0)
s = open(p).read()
if len(s.strip()) < 200:
    print(f"FAIL: stub-sized file ({len(s)} bytes)"); sys.exit(0)
exports_start = bool(re.search(r"export\s+(async\s+)?(function\s+startSnowEffect|const\s+startSnowEffect\s*=)", s))
makes_canvas = bool(re.search(r"createElement\(\s*[\x27\x22]canvas[\x27\x22]\s*\)", s, re.I)) or bool(re.search(r"<canvas[\s>]", s, re.I))
pe_none = bool(re.search(r"pointer-events\s*:\s*none", s, re.I)) or bool(re.search(r"pointerEvents\s*[=:]\s*[\x27\x22]none", s))
pos_fixed = bool(re.search(r"position\s*:\s*fixed", s, re.I)) or bool(re.search(r"position\s*[=:]\s*[\x27\x22]fixed", s))
raf = bool(re.search(r"requestAnimationFrame\s*\(", s))
storage_read = bool(re.search(r"chrome\.storage", s)) and bool(re.search(r"gvSnowEffect|GV_SNOW", s))
ok = exports_start and makes_canvas and pe_none and pos_fixed and raf and storage_read
print("PASS" if ok else f"FAIL: export={exports_start} canvas={makes_canvas} pe={pe_none} pos={pos_fixed} raf={raf} storage={storage_read}")
')

# ──────────────────────────────────────────────────────────────────────────────
# F2P_REGISTRATION (0.15): src/pages/content/index.tsx imports startSnowEffect
# from a snowEffect path AND calls startSnowEffect() inside the init pipeline.
# Behavioral: does not require the call to be at any particular line/order.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=$(run_gate_py F2P_REGISTRATION '
import re, os, sys
p = "src/pages/content/index.tsx"
if not os.path.exists(p):
    print("FAIL: content/index.tsx missing"); sys.exit(0)
s = open(p).read()
imports = bool(re.search(r"import\s+\{[^}]*startSnowEffect[^}]*\}\s+from\s+[\x27\x22][^\x27\x22]*snowEffect[^\x27\x22]*[\x27\x22]", s))
calls = bool(re.search(r"\bstartSnowEffect\s*\(", s))
# require at least one call site that is NOT inside the import line
call_lines = [ln for ln in s.splitlines() if re.search(r"\bstartSnowEffect\s*\(", ln) and not ln.lstrip().startswith("import")]
called = len(call_lines) >= 1
ok = imports and calls and called
print("PASS" if ok else f"FAIL: import={imports} call={calls} called_outside_import={called}")
')

# ──────────────────────────────────────────────────────────────────────────────
# F2P_POPUP_TOGGLE (0.20): src/pages/popup/Popup.tsx wires the popup UI:
#   - useState for a snow-effect boolean (any name containing "snow")
#   - mapping in the apply()/SettingsUpdate flow that writes gvSnowEffect
#   - UI element bound to the new state (a Switch/Checkbox/input checked= prop)
# Anti-overfit: matches the *behavior* (state ↔ storage payload ↔ UI) rather
# than the canonical variable name `snowEffectEnabled`.
# ──────────────────────────────────────────────────────────────────────────────
G4_PASS=$(run_gate_py F2P_POPUP_TOGGLE '
import re, os, sys
p = "src/pages/popup/Popup.tsx"
if not os.path.exists(p):
    print("FAIL: Popup.tsx missing"); sys.exit(0)
s = open(p).read()
# A useState hook whose identifier mentions snow (case-insensitive)
state_hook = bool(re.search(r"useState[<(][^>]*>\s*\(\s*(false|true|\{)\s*\).*", s)) and bool(re.search(r"[A-Za-z_][A-Za-z0-9_]*[Ss]now[A-Za-z0-9_]*", s))
# Direct: a useState line referencing snow
hook_line = bool(re.search(r"useState\s*<[^>]*>\s*\([^)]*\).*", s)) and bool(re.search(r"const\s*\[[^\]]*[Ss]now[^\]]*\]\s*=\s*useState", s))
# Storage payload mapping — must write gvSnowEffect somewhere
storage_write = bool(re.search(r"gvSnowEffect", s))
# UI binding: any JSX prop that ties a snow* state to checked=
ui_binding = bool(re.search(r"checked\s*=\s*\{[^}]*[Ss]now[^}]*\}", s))
ok = (hook_line or state_hook) and storage_write and ui_binding
print("PASS" if ok else f"FAIL: hook={hook_line or state_hook} storage_write={storage_write} ui={ui_binding}")
')

# ──────────────────────────────────────────────────────────────────────────────
# F2P_LIFECYCLE (0.15): the snow module has correct enable/disable lifecycle:
#   - appendChild (canvas attached to DOM somewhere)
#   - canvas.remove() OR removeChild (canvas detached on disable)
#   - cancelAnimationFrame (rAF loop torn down)
#   - addEventListener for chrome.storage.onChanged OR storage onChanged listener
# Rejects single-direction implementations that enable but never clean up.
# ──────────────────────────────────────────────────────────────────────────────
G5_PASS=$(run_gate_py F2P_LIFECYCLE '
import re, os, sys
candidates = ["src/pages/content/snowEffect/index.ts", "src/pages/content/snowEffect/index.tsx"]
p = next((c for c in candidates if os.path.exists(c)), None)
if not p:
    print("FAIL: snowEffect module missing"); sys.exit(0)
s = open(p).read()
attach = bool(re.search(r"\.appendChild\s*\(", s)) or bool(re.search(r"\.append\s*\(", s)) or bool(re.search(r"\.prepend\s*\(", s))
detach = bool(re.search(r"\.removeChild\s*\(", s)) or bool(re.search(r"canvas[\w.\?]*\.remove\s*\(", s)) or bool(re.search(r"\.remove\s*\(\s*\)", s))
caf = bool(re.search(r"cancelAnimationFrame\s*\(", s))
storage_listener = bool(re.search(r"storage[?.\s]*\.\s*onChanged[?.\s]*\.\s*addListener", s)) or bool(re.search(r"onChanged\.addListener", s))
ok = attach and detach and caf and storage_listener
print("PASS" if ok else f"FAIL: attach={attach} detach={detach} caf={caf} storageListener={storage_listener}")
')

# ──────────────────────────────────────────────────────────────────────────────
# F2P_TESTS_EXIST (0.10): test file exists at snowEffect/__tests__/ with at
# least 2 it() blocks and references both canvas (DOM assertion) and chrome
# storage simulation (the behavioral fixture pattern). Rejects empty stubs.
# ──────────────────────────────────────────────────────────────────────────────
G6_PASS=$(run_gate_py F2P_TESTS_EXIST '
import re, os, sys, glob
matches = glob.glob("src/pages/content/snowEffect/__tests__/*test*.ts*") + glob.glob("src/pages/content/snowEffect/__tests__/*test*.tsx") + glob.glob("src/pages/content/snowEffect/__tests__/*spec*.ts*")
if not matches:
    print("FAIL: no test file in snowEffect/__tests__/"); sys.exit(0)
p = matches[0]
s = open(p).read()
if len(s.strip()) < 100:
    print(f"FAIL: stub-sized test file ({len(s)} bytes)"); sys.exit(0)
its = len(re.findall(r"\bit\s*\(\s*[\x27\x22]", s)) + len(re.findall(r"\btest\s*\(\s*[\x27\x22]", s))
asserts = len(re.findall(r"\bexpect\s*\(", s))
mentions_canvas = bool(re.search(r"canvas", s, re.I))
mentions_storage = bool(re.search(r"chrome\.storage|gvSnowEffect", s))
ok = its >= 2 and asserts >= 3 and mentions_canvas and mentions_storage
print("PASS" if ok else f"FAIL: its={its} asserts={asserts} canvas={mentions_canvas} storage={mentions_storage}")
')

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
verdicts = [s == "true" for s in sys.argv[2:8]]
ids = ["F2P_STORAGE_KEY", "F2P_MODULE_EXISTS", "F2P_REGISTRATION", "F2P_POPUP_TOGGLE", "F2P_LIFECYCLE", "F2P_TESTS_EXIST"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(ids, verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula ──────────────────────────────────────────
declare -A WEIGHTS
WEIGHTS[F2P_STORAGE_KEY]=0.15
WEIGHTS[F2P_MODULE_EXISTS]=0.25
WEIGHTS[F2P_REGISTRATION]=0.15
WEIGHTS[F2P_POPUP_TOGGLE]=0.20
WEIGHTS[F2P_LIFECYCLE]=0.15
WEIGHTS[F2P_TESTS_EXIST]=0.10
WEIGHT_SUM=1.00

declare -A VERDICTS
VERDICTS[F2P_STORAGE_KEY]=$G1_PASS
VERDICTS[F2P_MODULE_EXISTS]=$G2_PASS
VERDICTS[F2P_REGISTRATION]=$G3_PASS
VERDICTS[F2P_POPUP_TOGGLE]=$G4_PASS
VERDICTS[F2P_LIFECYCLE]=$G5_PASS
VERDICTS[F2P_TESTS_EXIST]=$G6_PASS

base_reward=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")

# P2P_REGRESSION: informational only — diagnostic/penalty only (per CLAUDE.md / scoring_traps.md)
p2p_failed=false

# F2P: at least one gate must pass for non-zero reward (when no inner reward exists)
f2p_any_pass=false
for gid in "${!WEIGHTS[@]}"; do
    if [[ "${VERDICTS[$gid]:-false}" == "true" ]]; then
        f2p_any_pass=true
        break
    fi
done

# Compute final reward (weighted-replace)
if $p2p_failed || (! $f2p_any_pass && [[ $(python3 -c "print(float('$base_reward') <= 0)") == "True" ]]); then
    reward=0.0
else
    reward=$(python3 -c "
existing = float('$base_reward')
weight_sum = $WEIGHT_SUM
inner = max(0.0, 1.0 - weight_sum)
r = existing * inner
weights = {'F2P_STORAGE_KEY': 0.15, 'F2P_MODULE_EXISTS': 0.25, 'F2P_REGISTRATION': 0.15, 'F2P_POPUP_TOGGLE': 0.20, 'F2P_LIFECYCLE': 0.15, 'F2P_TESTS_EXIST': 0.10}
verdicts = {'F2P_STORAGE_KEY': '$G1_PASS', 'F2P_MODULE_EXISTS': '$G2_PASS', 'F2P_REGISTRATION': '$G3_PASS', 'F2P_POPUP_TOGGLE': '$G4_PASS', 'F2P_LIFECYCLE': '$G5_PASS', 'F2P_TESTS_EXIST': '$G6_PASS'}
for gid, w in weights.items():
    if verdicts.get(gid) == 'true':
        r += w
print(f'{max(0.0, min(1.0, r)):.6f}')
")
fi

echo "$reward" > "$REWARD_FILE"
echo "─────────────────────────────────────────────────"
echo "Gate verdicts:"
for gid in F2P_STORAGE_KEY F2P_MODULE_EXISTS F2P_REGISTRATION F2P_POPUP_TOGGLE F2P_LIFECYCLE F2P_TESTS_EXIST; do
    echo "  $gid = ${VERDICTS[$gid]}"
done
echo "Final reward: $reward"
