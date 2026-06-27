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
