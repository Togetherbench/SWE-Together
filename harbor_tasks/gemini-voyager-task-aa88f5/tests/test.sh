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
