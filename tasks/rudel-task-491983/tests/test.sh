#!/usr/bin/env bash
# CI source: .github/workflows/ci.yml runs `bunx turbo run lint check-types test build`
# with PG_CONNECTION_STRING + CLICKHOUSE_URL secrets. Integration tests not runnable
# without backend infra, so we use behavioral + structural verification instead.
set +e

REPO_DIR="/workspace/rudel"
REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"

declare -A WEIGHTS
WEIGHTS["avgOrNull_in_details"]="0.25"
WEIGHTS["zero_sessions_null_check"]="0.20"
WEIGHTS["git_remote_nav_fallback"]="0.20"
WEIGHTS["func_details_exists"]="0.15"

declare -A verdicts
verdicts["avgOrNull_in_details"]="false"
verdicts["zero_sessions_null_check"]="false"
verdicts["git_remote_nav_fallback"]="false"
verdicts["func_details_exists"]="false"

p2p_failed="false"
f2p_any_pass="false"
SVC_FILE="$REPO_DIR/apps/api/src/services/project.service.ts"
WEB_FILE="$REPO_DIR/apps/web/src/pages/dashboard/ProjectsListPage.tsx"

# ── Gate: avgOrNull_in_details ─────────────────────────────────────────
# In getProjectDetails, the ClickHouse query must not use bare AVG() on
# aggregate columns (which emits `nan` on 0-row result sets → invalid
# JSON → 500). Must use avgOrNull (or equivalent safe aggregate).
if [ -f "$SVC_FILE" ]; then
    if python3 -c "
import re

with open('$SVC_FILE') as f:
    content = f.read()

# Extract the getProjectDetails function body (from export to closing brace).
# Find all exported function declarations.
func_start = content.find('export async function getProjectDetails')
if func_start == -1:
    exit(1)

# Find the function body by tracking braces from the opening { after params.
brace_start = content.find('{', content.find(')', func_start))
if brace_start == -1:
    exit(1)

depth = 0
func_end = brace_start
for i in range(brace_start, len(content)):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            func_end = i + 1
            break

func_body = content[func_start:func_end]

# Within this function body, find the SQL template string (backtick-quoted).
# The query uses backtick template strings with \${} interpolation.
# Check that bare round(AVG( patterns near avg_session_duration_min
# or success_rate have been replaced with safe patterns.

# Track the line containing avg_session_duration_min AS alias
lines = func_body.split('\n')
for i, line in enumerate(lines):
    if 'avg_session_duration_min' in line and 'as' in line.lower():
        # This line must NOT contain bare round(AVG( — it must use a safe pattern.
        if re.search(r'round\(AVG\(', line):
            exit(1)  # Still using bare AVG — buggy!
        # Must contain either avgOrNull, or a conditional like count() > 0
        if 'avgOrNull' in line or ('count()' in line and 'AVG' in line):
            exit(0)  # Fixed!
        # If we got here, line was modified but not with a recognized safe pattern
        # Allow any non-AVG modification (the agent might use a different approach)
        if 'AVG' not in line:
            exit(0)  # AVG removed or replaced entirely
        exit(1)  # Still has AVG without safety wrapper

    if 'success_rate' in line and 'as' in line.lower() and 'prev' not in line.lower():
        # Similar check for success_rate in the details query
        if re.search(r'round\(AVG\(', line):
            exit(1)
        if 'avgOrNull' in line or ('count()' in line and 'AVG' in line):
            pass  # line is fixed, continue
        elif 'AVG' in line:
            exit(1)
        else:
            pass  # AVG removed — acceptable

# If we couldn't find avg_session_duration_min alias (agent restructured code),
# fall back to checking that avgOrNull appears in the function body.
if 'avgOrNull' in func_body:
    exit(0)
# Last resort: check if the specific buggy aggregate pattern is gone
# from getProjectDetails' query.
if re.search(r'round\(AVG\(actual_duration_min\)', func_body):
    exit(1)
exit(0)
" 2>/dev/null; then
        verdicts["avgOrNull_in_details"]="true"
    fi
fi

# ── Gate: zero_sessions_null_check ─────────────────────────────────────
# The null guard in getProjectDetails must reject rows where total_sessions === 0,
# not just null rows. Buggy: if (!row) return null → Fixed: if (!row || row.total_sessions === 0)
if [ -f "$SVC_FILE" ]; then
    if python3 -c "
import re
with open('$SVC_FILE') as f:
    content = f.read()

# Extract getProjectDetails function body
func_start = content.find('export async function getProjectDetails')
if func_start == -1:
    exit(1)
brace_start = content.find('{', content.find(')', func_start))
if brace_start == -1:
    exit(1)
depth = 0
func_end = brace_start
for i in range(brace_start, len(content)):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            func_end = i + 1
            break
func_body = content[func_start:func_end]

# The null check must include total_sessions condition
if re.search(r'row\.total_sessions\s*[=!]==?\s*0', func_body):
    exit(0)
# Alternative: checking count or length
if re.search(r'row\.total_sessions\s*<\s*1', func_body):
    exit(0)
# Also accept: !row?.total_sessions (TypeScript optional chaining)
if re.search(r'!row\?\s*\.\s*total_sessions', func_body):
    exit(0)
exit(1)
" 2>/dev/null; then
        verdicts["zero_sessions_null_check"]="true"
    fi
fi

# ── Gate: git_remote_nav_fallback ──────────────────────────────────────
# ProjectsListPage handleRowClick must use git_remote (or similar key) as
# a fallback navigation key, not just project_path which may be empty for
# open-source projects. Buggy: encodeProjectPath(row.project_path) only.
# Fixed: must have a fallback chain like row.git_remote || row.project_path.
if [ -f "$WEB_FILE" ]; then
    if python3 -c "
import re
with open('$WEB_FILE') as f:
    content = f.read()

# Find handleRowClick function body
func_pos = content.find('handleRowClick')
if func_pos == -1:
    exit(1)

# Find the opening brace of the arrow function body
arrow = content.find('=>', func_pos)
if arrow == -1:
    exit(1)
brace = content.find('{', arrow)
if brace == -1:
    exit(1)

# Track braces to find function body end
depth = 0
end = brace
for i in range(brace, min(brace + 300, len(content))):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
fn_body = content[func_pos:end]

# The navigation key must use a fallback (not just project_path alone).
# Accept: row.git_remote || row.project_path, or any multi-part key.
if 'git_remote' in fn_body and 'project_path' in fn_body:
    exit(0)
# Accept any || fallback chain involving project_path
if re.search(r'row\.\w+\s*\|\|\s*row\.project_path', fn_body):
    exit(0)
if re.search(r'row\.project_path\s*\|\|\s*row\.\w+', fn_body):
    exit(0)
# Accept nullish coalescing: row.project_path ?? row.x
if re.search(r'row\.\w+\s*\?\?\s*row\.project_path', fn_body):
    exit(0)
# Accept ternary or conditional fallback
if re.search(r'row\.\w+\s*\?\s*row\.\w+\s*:\s*row\.project_path', fn_body):
    exit(0)
if re.search(r'row\.project_path\s*\?\s*row\.project_path\s*:', fn_body):
    pass  # self-referential, still broken
else:
    # Check if the old single-key pattern is gone
    if re.search(r'encodeProjectPath\(row\.project_path\)', fn_body):
        exit(1)  # Still uses single key — buggy!
    exit(0)  # Code changed; accept
exit(1)
" 2>/dev/null; then
        verdicts["git_remote_nav_fallback"]="true"
    fi
fi

# ── Gate: func_details_exists ─────────────────────────────────────────
# getProjectDetails must still exist and be exported (anti-stub)
if [ -f "$SVC_FILE" ]; then
    if grep -q 'export.*function getProjectDetails' "$SVC_FILE" 2>/dev/null; then
        verdicts["func_details_exists"]="true"
    fi
fi

# ── P2P_REGRESSION: files_intact ───────────────────────────────────────
if [ ! -f "$SVC_FILE" ]; then
    p2p_failed="true"
fi
if [ ! -f "$WEB_FILE" ]; then
    p2p_failed="true"
fi
# Anti-stub: files must have substantial content
SVC_LINES=$(wc -l < "$SVC_FILE" 2>/dev/null || echo "0")
if [ "$SVC_LINES" -lt 200 ]; then
    p2p_failed="true"
fi
WEB_LINES=$(wc -l < "$WEB_FILE" 2>/dev/null || echo "0")
if [ "$WEB_LINES" -lt 50 ]; then
    p2p_failed="true"
fi

# ── P2P_REGRESSION: func_rowclick_exists ───────────────────────────────
if [ -f "$WEB_FILE" ]; then
    if ! grep -q 'handleRowClick' "$WEB_FILE" 2>/dev/null; then
        p2p_failed="true"
    fi
fi

# ── Reward computation (weighted-replace formula) ──────────────────────

# Emit verdicts to gates.json
python3 -c "
import json
vs = {
    'avgOrNull_in_details': '${verdicts[avgOrNull_in_details]}' == 'true',
    'zero_sessions_null_check': '${verdicts[zero_sessions_null_check]}' == 'true',
    'git_remote_nav_fallback': '${verdicts[git_remote_nav_fallback]}' == 'true',
    'func_details_exists': '${verdicts[func_details_exists]}' == 'true',
}
with open('$GATES_FILE', 'w') as f:
    json.dump({'verdicts': vs}, f, indent=2)
" 2>/dev/null

# Determine f2p_any_pass
for gid in "${!WEIGHTS[@]}"; do
    if [ "${verdicts[$gid]}" = "true" ]; then
        f2p_any_pass="true"
        break
    fi
done

reward=0.0
existing=0.0

if [ "$p2p_failed" = "true" ] || [ "$f2p_any_pass" = "false" ]; then
    reward=0.0
else
    # inner_weight = max(0.0, 1.0 - sum(WEIGHTS))
    inner_weight=$(python3 -c "print(max(0.0, 1.0 - (${WEIGHTS[avgOrNull_in_details]:-0} + ${WEIGHTS[zero_sessions_null_check]:-0} + ${WEIGHTS[git_remote_nav_fallback]:-0} + ${WEIGHTS[func_details_exists]:-0})))")
    reward=$(python3 -c "print(float($existing) * float($inner_weight))")
    for gid in "${!WEIGHTS[@]}"; do
        if [ "${verdicts[$gid]}" = "true" ]; then
            w="${WEIGHTS[$gid]}"
            reward=$(python3 -c "print(float('$reward') + float('$w'))")
        fi
    done
fi

echo "$reward" > "$REWARD_FILE"

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
