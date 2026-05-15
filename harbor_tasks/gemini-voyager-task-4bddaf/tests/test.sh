#!/usr/bin/env bash
# Manifest-driven verifier for gemini-voyager-task-4bddaf (popup section reorder).
# This task was originally migrated to the SWE-rebench template, but its canonical
# patch adds zero new vitest tests, so the SWE-rebench fallback (`overall pass rate`)
# is meaningless for grading. We restore manifest-driven scoring per CLAUDE.md's
# v0.4.3.1 weighted-replace formula.
#
#   reward = sum(weight_i)  for each F2P gate i that passes
# All gates are independent boolean checks. P2P_REGRESSION (vitest suite) is
# informational only — never feeds bounded penalty/diagnostics (per CLAUDE.md guidance).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
mkdir -p "$LOGS_DIR"

REPO_DIR="/workspace/repo"
cd "$REPO_DIR" || { echo "ERROR: cd $REPO_DIR" >&2; echo 0.0 > "$LOGS_DIR/reward.txt"; exit 1; }

LOG="$LOGS_DIR/test_run.log"
GATES_JSON="$LOGS_DIR/gates.json"
: > "$LOG"
echo "{}" > "$GATES_JSON"

# ── F2P_TYPECHECK (0.10) ───────────────────────────────────────────────────────
echo "[gate] F2P_TYPECHECK" | tee -a "$LOG"
bun run typecheck > /tmp/typecheck.log 2>&1
F2P_TYPECHECK=$?
[ $F2P_TYPECHECK -eq 0 ] && F2P_TYPECHECK_PASS=1 || F2P_TYPECHECK_PASS=0
echo "  result: $F2P_TYPECHECK_PASS" | tee -a "$LOG"

# ── F2P_STORAGE_KEY (0.15) ─────────────────────────────────────────────────────
echo "[gate] F2P_STORAGE_KEY" | tee -a "$LOG"
F2P_STORAGE_KEY_PASS=$(python3 - <<'PYEOF' 2>/dev/null
import re
try:
    with open('/workspace/repo/src/core/types/common.ts') as f:
        text = f.read()
    cleaned = re.sub(r'//.*', '', text)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    matches = re.findall(r"(GV_\w*(?:POPUP|SECTION|ORDER|REORDER)\w*)\s*:\s*'", cleaned)
    print(1 if len(matches) > 0 else 0)
except Exception:
    print(0)
PYEOF
)
[ -z "$F2P_STORAGE_KEY_PASS" ] && F2P_STORAGE_KEY_PASS=0
echo "  result: $F2P_STORAGE_KEY_PASS" | tee -a "$LOG"

# ── F2P_SECTION_ARRAY (0.15) ───────────────────────────────────────────────────
echo "[gate] F2P_SECTION_ARRAY" | tee -a "$LOG"
F2P_SECTION_ARRAY_PASS=$(python3 - <<'PYEOF' 2>/dev/null
import re
try:
    with open('/workspace/repo/src/pages/popup/Popup.tsx') as f:
        text = f.read()
    cleaned = re.sub(r'//.*', '', text)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    arrays = re.findall(r"const\s+(\w*(?:SECTION|POPUP|ORDER)\w*)\s*=\s*\[([^\]]{50,})\]", cleaned, re.DOTALL)
    found = any(len(re.findall(r"'([^']+)'", body)) >= 10 for _, body in arrays)
    print(1 if found else 0)
except Exception:
    print(0)
PYEOF
)
[ -z "$F2P_SECTION_ARRAY_PASS" ] && F2P_SECTION_ARRAY_PASS=0
echo "  result: $F2P_SECTION_ARRAY_PASS" | tee -a "$LOG"

# ── F2P_REORDER_UI (0.20) ──────────────────────────────────────────────────────
echo "[gate] F2P_REORDER_UI" | tee -a "$LOG"
F2P_REORDER_UI_PASS=$(python3 - <<'PYEOF' 2>/dev/null
import re
try:
    with open('/workspace/repo/src/pages/popup/Popup.tsx') as f:
        text = f.read()
    cleaned = re.sub(r'//.*', '', text)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    s = 0
    if re.search(r'<(?:button|div)[^>]*onClick.*?<svg.*?</svg>', cleaned, re.DOTALL) and re.search(r'<polyline[^>]*points=', cleaned):
        s += 1
    if re.search(r'(?:aria-label|title)\s*=\s*\{[^}]*?(?:move|Move|up|down|Up|Down|上|下)', cleaned):
        s += 1
    print(1 if s >= 2 else 0)
except Exception:
    print(0)
PYEOF
)
[ -z "$F2P_REORDER_UI_PASS" ] && F2P_REORDER_UI_PASS=0
echo "  result: $F2P_REORDER_UI_PASS" | tee -a "$LOG"

# ── F2P_MOVE_LOGIC (0.20) ──────────────────────────────────────────────────────
echo "[gate] F2P_MOVE_LOGIC" | tee -a "$LOG"
F2P_MOVE_LOGIC_PASS=$(python3 - <<'PYEOF' 2>/dev/null
import re
try:
    with open('/workspace/repo/src/pages/popup/Popup.tsx') as f:
        text = f.read()
    cleaned = re.sub(r'//.*', '', text)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    s = 0
    if re.search(r'\.(?:indexOf|findIndex)\s*\(', cleaned):
        s += 1
    if re.search(r'const\s+\w+\s*=\s*\[\.\.\.\w+\]', cleaned) or re.search(r'\[\w+\]\s*=\s*\[\w+\]\s*,\s*\[\w+\]\s*=\s*\[\w+\]', cleaned):
        s += 1
    if re.search(r'set\w*(?:Section|Order|Reorder)\w*\s*\(', cleaned):
        s += 1
    print(1 if s >= 2 else 0)
except Exception:
    print(0)
PYEOF
)
[ -z "$F2P_MOVE_LOGIC_PASS" ] && F2P_MOVE_LOGIC_PASS=0
echo "  result: $F2P_MOVE_LOGIC_PASS" | tee -a "$LOG"

# ── F2P_STORAGE_SAVE (0.15) ────────────────────────────────────────────────────
# Tightened: storage.set call must mention SECTION/ORDER/REORDER within a 500-char
# proximity window so a pre-existing settings save (irrelevant to reorder) doesn't pass.
echo "[gate] F2P_STORAGE_SAVE" | tee -a "$LOG"
F2P_STORAGE_SAVE_PASS=$(python3 - <<'PYEOF' 2>/dev/null
import re
try:
    with open('/workspace/repo/src/pages/popup/Popup.tsx') as f:
        text = f.read()
    cleaned = re.sub(r'//.*', '', text)
    cleaned = re.sub(r'/\*.*?\*/', '', cleaned, flags=re.DOTALL)
    found = False
    for m in re.finditer(r'(?:chrome\.storage\.sync\.set|setSyncStorage)\s*\(', cleaned):
        start = max(0, m.start() - 200)
        end = min(len(cleaned), m.end() + 300)
        window = cleaned[start:end]
        if re.search(r'(?:SECTION|Section|section|ORDER|Order|order|REORDER|Reorder|reorder)', window):
            found = True
            break
    print(1 if found else 0)
except Exception:
    print(0)
PYEOF
)
[ -z "$F2P_STORAGE_SAVE_PASS" ] && F2P_STORAGE_SAVE_PASS=0
echo "  result: $F2P_STORAGE_SAVE_PASS" | tee -a "$LOG"

# ── F2P_I18N (0.05) ────────────────────────────────────────────────────────────
echo "[gate] F2P_I18N" | tee -a "$LOG"
F2P_I18N_PASS=$(python3 - <<'PYEOF' 2>/dev/null
import json
try:
    with open('/workspace/repo/src/locales/en/messages.json') as f:
        data = json.load(f)
    up = data.get('moveSectionUp', {}).get('message', '')
    down = data.get('moveSectionDown', {}).get('message', '')
    print(1 if (up.strip() and down.strip()) else 0)
except Exception:
    print(0)
PYEOF
)
[ -z "$F2P_I18N_PASS" ] && F2P_I18N_PASS=0
echo "  result: $F2P_I18N_PASS" | tee -a "$LOG"

# ── P2P_REGRESSION_TESTS (informational) ──────────────────────────────────────
# Per CLAUDE.md: P2P_REGRESSION is informational only — never feeds bounded penalty/diagnostics.
# Run vitest, log result, but don't gate.
echo "[gate] P2P_REGRESSION_TESTS (informational)" | tee -a "$LOG"
bun run test > /tmp/vitest.log 2>&1
P2P_REGRESSION_RC=$?
[ $P2P_REGRESSION_RC -eq 0 ] && P2P_REGRESSION_PASS=1 || P2P_REGRESSION_PASS=0
echo "  result: $P2P_REGRESSION_PASS (informational, not diagnostic)" | tee -a "$LOG"

# ── compute reward (weighted-replace, per CLAUDE.md) ───────────────────────────
python3 - "$LOGS_DIR" \
    "$F2P_TYPECHECK_PASS" \
    "$F2P_STORAGE_KEY_PASS" \
    "$F2P_SECTION_ARRAY_PASS" \
    "$F2P_REORDER_UI_PASS" \
    "$F2P_MOVE_LOGIC_PASS" \
    "$F2P_STORAGE_SAVE_PASS" \
    "$F2P_I18N_PASS" \
    "$P2P_REGRESSION_PASS" <<'PYEOF'
import json, sys
logs_dir = sys.argv[1]
verdicts = {
    "F2P_TYPECHECK":     int(sys.argv[2]),
    "F2P_STORAGE_KEY":   int(sys.argv[3]),
    "F2P_SECTION_ARRAY": int(sys.argv[4]),
    "F2P_REORDER_UI":    int(sys.argv[5]),
    "F2P_MOVE_LOGIC":    int(sys.argv[6]),
    "F2P_STORAGE_SAVE":  int(sys.argv[7]),
    "F2P_I18N":          int(sys.argv[8]),
    "P2P_REGRESSION_TESTS": int(sys.argv[9]),
}
WEIGHTS = {
    "F2P_TYPECHECK":     0.10,
    "F2P_STORAGE_KEY":   0.15,
    "F2P_SECTION_ARRAY": 0.15,
    "F2P_REORDER_UI":    0.20,
    "F2P_MOVE_LOGIC":    0.20,
    "F2P_STORAGE_SAVE":  0.15,
    "F2P_I18N":          0.05,
}
# weights sum to 1.00 — inner_share = 0; legacy reward fully replaced
existing = 0.0
inner_weight = max(0.0, 1.0 - sum(float(w) for w in WEIGHTS.values()))
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += float(w)
# P2P_REGRESSION is informational — never zeros reward (CLAUDE.md v0.4.3.1)
reward = max(0.0, min(1.0, reward))
with open(f"{logs_dir}/gates.json", "w") as f:
    json.dump({"verdicts": verdicts, "weights": WEIGHTS, "reward": reward}, f, indent=2)
with open(f"{logs_dir}/reward.txt", "w") as f:
    f.write(f"{reward:.6f}\n")
print(f"[reward] {reward:.4f}  passed=" + ",".join(g for g,v in verdicts.items() if v))
PYEOF

cat "$LOGS_DIR/reward.txt"
