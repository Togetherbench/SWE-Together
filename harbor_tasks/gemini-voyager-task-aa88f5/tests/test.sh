#!/usr/bin/env bash
# Custom structural verifier for gemini-voyager-task-aa88f5.
#
# Task: fix import-folder dialog text colors in light mode + menu icon
# alignment in the Gemini Voyager browser extension. Pure CSS/TS UI bug —
# repo has no vitest tests for visual styling, so the SWE-rebench template
# (`bun x vitest run`) returns 0/0 in both base and patched states. We
# instead delegate to tests/check_css.py which parses public/contentStyle.css
# and src/pages/content/folder/manager.ts and checks for the .theme-host /
# body theme overrides + the menu-item flex+align-items rule.
#
# F2P weights (sum = 0.80) — mirror tests/test_manifest.yaml:
#   F2P_DIALOG_TITLE_LIGHT       0.20
#   F2P_STRATEGY_LABEL_LIGHT     0.15
#   F2P_RADIO_OPTIONS_LIGHT      0.15
#   F2P_DIALOG_BUTTONS_LIGHT     0.10
#   F2P_FILE_ELEMENTS_LIGHT      0.10
#   F2P_MENU_ITEM_FLEX           0.10
#
# inner_share = 1 - 0.80 = 0.20 (scales any pre-existing reward, kept at 0).
#
# P2P_REGRESSION gates are INFORMATIONAL ONLY — never zero the reward
# (per CLAUDE.md golden rule on P2P semantics).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
EVAL_DIR="${EVAL_DIR:-/tests}"
mkdir -p "$LOGS_DIR"

REPO_DIR="/workspace/gemini-voyager"
CHECK_CSS=""
for cand in "$EVAL_DIR/check_css.py" "$TASK_DIR/tests/check_css.py" "/tests/check_css.py"; do
    if [ -f "$cand" ]; then CHECK_CSS="$cand"; break; fi
done
if [ -z "$CHECK_CSS" ]; then
    echo "ERROR: check_css.py not found in $EVAL_DIR or $TASK_DIR/tests" >&2
    echo 0.0 > "$LOGS_DIR/reward.txt"
    exit 0
fi

LOG="$LOGS_DIR/test_run.log"
echo "[eval] structural verifier for gemini-voyager-task-aa88f5" | tee -a "$LOG"
echo "[eval] check_css.py = $CHECK_CSS" | tee -a "$LOG"
echo "[eval] REPO_DIR     = $REPO_DIR"  | tee -a "$LOG"

# Sanity: required source files exist
for f in "$REPO_DIR/public/contentStyle.css" "$REPO_DIR/src/pages/content/folder/manager.ts"; do
    if [ ! -f "$f" ]; then
        echo "[eval] WARN: missing $f" | tee -a "$LOG"
    fi
done

run_gate() {
    local gid="$1" tname="$2"
    python3 "$CHECK_CSS" --test "$tname" >>"$LOG" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then echo "PASS"; else echo "FAIL"; fi
}

DIALOG_TITLE=$(run_gate F2P_DIALOG_TITLE_LIGHT       dialog-title-light)
STRATEGY_LBL=$(run_gate F2P_STRATEGY_LABEL_LIGHT     strategy-label-light)
RADIO_OPTS=$(  run_gate F2P_RADIO_OPTIONS_LIGHT      radio-options-light)
DIALOG_BTNS=$( run_gate F2P_DIALOG_BUTTONS_LIGHT     dialog-buttons-light)
FILE_ELEMS=$(  run_gate F2P_FILE_ELEMENTS_LIGHT      file-elements-light)
MENU_FLEX=$(   run_gate F2P_MENU_ITEM_FLEX           menu-item-flex)
P2P_CSSVALID=$(run_gate P2P_NO_CSS_ERRORS            css-valid)
P2P_DARK=$(    run_gate P2P_DARK_THEME_INTACT        dark-theme-intact)

echo "[eval] F2P_DIALOG_TITLE_LIGHT      = $DIALOG_TITLE" | tee -a "$LOG"
echo "[eval] F2P_STRATEGY_LABEL_LIGHT    = $STRATEGY_LBL" | tee -a "$LOG"
echo "[eval] F2P_RADIO_OPTIONS_LIGHT     = $RADIO_OPTS"   | tee -a "$LOG"
echo "[eval] F2P_DIALOG_BUTTONS_LIGHT    = $DIALOG_BTNS"  | tee -a "$LOG"
echo "[eval] F2P_FILE_ELEMENTS_LIGHT     = $FILE_ELEMS"   | tee -a "$LOG"
echo "[eval] F2P_MENU_ITEM_FLEX          = $MENU_FLEX"    | tee -a "$LOG"
echo "[eval] P2P_NO_CSS_ERRORS           = $P2P_CSSVALID  (informational)" | tee -a "$LOG"
echo "[eval] P2P_DARK_THEME_INTACT       = $P2P_DARK      (informational)" | tee -a "$LOG"

python3 - "$LOGS_DIR" \
    "$DIALOG_TITLE" "$STRATEGY_LBL" "$RADIO_OPTS" "$DIALOG_BTNS" "$FILE_ELEMS" "$MENU_FLEX" \
    "$P2P_CSSVALID" "$P2P_DARK" <<'PYEOF'
import json, sys
from pathlib import Path

logs_dir = Path(sys.argv[1])
(dt, sl, ro, db, fe, mf, pcss, pdark) = sys.argv[2:10]

def b(s): return s == "PASS"

verdicts = {
    "F2P_DIALOG_TITLE_LIGHT":   b(dt),
    "F2P_STRATEGY_LABEL_LIGHT": b(sl),
    "F2P_RADIO_OPTIONS_LIGHT":  b(ro),
    "F2P_DIALOG_BUTTONS_LIGHT": b(db),
    "F2P_FILE_ELEMENTS_LIGHT":  b(fe),
    "F2P_MENU_ITEM_FLEX":       b(mf),
}

WEIGHTS = {
    "F2P_DIALOG_TITLE_LIGHT":   0.20,
    "F2P_STRATEGY_LABEL_LIGHT": 0.15,
    "F2P_RADIO_OPTIONS_LIGHT":  0.15,
    "F2P_DIALOG_BUTTONS_LIGHT": 0.10,
    "F2P_FILE_ELEMENTS_LIGHT":  0.10,
    "F2P_MENU_ITEM_FLEX":       0.10,
}

# Weighted-replace reward formula (per CLAUDE.md). P2P_REGRESSION is
# informational only — never zeros the reward.
existing = 0.0
inner_share = max(0.0, 1.0 - sum(WEIGHTS.values()))  # 0.20
reward = existing * inner_share
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
reward = max(0.0, min(1.0, reward))

p2p = {
    "P2P_NO_CSS_ERRORS":     b(pcss),
    "P2P_DARK_THEME_INTACT": b(pdark),
}

print(f"\n=== F2P passed: {sum(1 for v in verdicts.values() if v)}/{len(verdicts)} ===")
print(f"=== reward = {reward:.4f} ===")

all_gates = {**{k: ("true" if v else "false") for k, v in verdicts.items()},
             **{k: ("true" if v else "false") for k, v in p2p.items()}}
(logs_dir / "gates.json").write_text(json.dumps(all_gates))
(logs_dir / "reward.txt").write_text(f"{reward:.6f}\n")
PYEOF

cat "$LOGS_DIR/reward.txt"

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
