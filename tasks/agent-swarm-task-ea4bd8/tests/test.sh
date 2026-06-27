#!/usr/bin/env bash
# Custom structural verifier for agent-swarm-task-ea4bd8.
#
# This task is a Dockerfile/docker-entrypoint.sh refactor (no test files
# added by the canonical patch and the upstream repo's bun:test suite is
# unrelated to the changes — running `bun test` produces noise that does
# not measure the agent's work).  Therefore we score by inspecting the
# files the canonical patch actually touches:
#   - Dockerfile.worker
#   - docker-entrypoint.sh
#   - new-ui/src/api/hooks/use-agents.ts
#
# F2P weights (sum = 1.0) — mirror tests/test_manifest.yaml:
#   dockerfile_apt_consolidation         0.25
#   dockerfile_npm_pinned                0.20
#   entrypoint_mcp_json_jq               0.25
#   dockerfile_marketplace_build_time    0.15
#   use_agents_lazy                      0.15
#
# P2P_REGRESSION gates are INFORMATIONAL ONLY — never zero the reward
# (per CLAUDE.md golden rule on P2P semantics).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
mkdir -p "$LOGS_DIR"

CONFIG="$TASK_DIR/tests/install_config.json"
REPO_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG'))['repo_dir'])" 2>/dev/null || echo "/workspace/agent-swarm")

cd "$REPO_DIR" || { echo "ERROR: cd $REPO_DIR" >&2; echo 0.0 > "$LOGS_DIR/reward.txt"; exit 1; }

LOG="$LOGS_DIR/test_run.log"
echo "[eval] structural verifier for agent-swarm-task-ea4bd8 (REPO_DIR=$REPO_DIR)" | tee -a "$LOG"

python3 - "$REPO_DIR" "$LOGS_DIR" <<'PYEOF' 2>&1 | tee -a "$LOG"
import json, os, re, sys
from pathlib import Path

repo = Path(sys.argv[1])
logs_dir = Path(sys.argv[2])

dockerfile = repo / "Dockerfile.worker"
entrypoint = repo / "docker-entrypoint.sh"
use_agents = repo / "new-ui/src/api/hooks/use-agents.ts"

def read(p):
    try:
        return p.read_text()
    except Exception as e:
        print(f"  [warn] could not read {p}: {e}")
        return ""

df = read(dockerfile)
ep = read(entrypoint)
ua = read(use_agents)

verdicts = {}

# === F2P: dockerfile_apt_consolidation ===
# After fix, there should be ~1 apt-get install RUN block (down from 3).
# Heuristic: count RUN-blocks containing both `apt-get update` and
# `apt-get install`.  Pass if <=2 (one bootstrap + one main install is
# acceptable, which matches the canonical patch).
print("=== F2P: dockerfile_apt_consolidation ===")
run_blocks = re.split(r"^RUN\b", df, flags=re.MULTILINE)
apt_install_blocks = sum(1 for b in run_blocks if "apt-get install" in b)
print(f"  RUN blocks containing `apt-get install`: {apt_install_blocks}")
verdicts["dockerfile_apt_consolidation"] = apt_install_blocks <= 2
print(f"  verdict: {'PASS' if verdicts['dockerfile_apt_consolidation'] else 'FAIL'}")

# === F2P: dockerfile_npm_pinned ===
# `npm install -g` block should not contain @latest for wts/qa-use; should
# pin specific versions (anything with @<digit>.<digit>).
print("=== F2P: dockerfile_npm_pinned ===")
# Capture the npm install -g block: from the marker to the next blank line
# or end-of-RUN sentinel. Use a permissive pattern that handles backslash
# line continuations.
npm_match = re.search(
    r"npm\s+install\s+-g[\s\S]*?(?:&&\s*qa-use\s+install-deps|^\s*$|\Z)",
    df, re.MULTILINE,
)
npm_block = npm_match.group(0) if npm_match else ""
print(f"  npm install block found: {bool(npm_block)} ({len(npm_block)} chars)")
# Also accept @latest detection in the broader npm context (the buggy state
# had `@desplega.ai/wts@latest`, `@desplega.ai/qa-use@latest`).
contains_at_latest_for_target = bool(re.search(
    r"(wts|qa-use|sentry/cli|localtunnel)@latest", npm_block))
pinned_count = len(re.findall(r"@\d+\.\d+", npm_block))
print(f"  contains <target>@latest: {contains_at_latest_for_target}")
print(f"  pinned (@N.N) entries: {pinned_count}")
verdicts["dockerfile_npm_pinned"] = (not contains_at_latest_for_target) and pinned_count >= 3
print(f"  verdict: {'PASS' if verdicts['dockerfile_npm_pinned'] else 'FAIL'}")

# === F2P: entrypoint_mcp_json_jq ===
# docker-entrypoint.sh should generate the .mcp.json via jq, not via heredoc.
# Detect heredoc generation of mcp.json (the buggy state).
print("=== F2P: entrypoint_mcp_json_jq ===")
uses_jq = bool(re.search(r"jq\s+(?:-n|--arg|--argjson)", ep)) and ".mcp.json" in ep
heredoc_mcp = bool(re.search(r"cat\s+>[^\n]*\.mcp\.json[^\n]*<<\s*EOF", ep))
print(f"  uses jq for MCP generation: {uses_jq}")
print(f"  uses heredoc for MCP JSON: {heredoc_mcp}")
verdicts["entrypoint_mcp_json_jq"] = uses_jq and not heredoc_mcp
print(f"  verdict: {'PASS' if verdicts['entrypoint_mcp_json_jq'] else 'FAIL'}")

# === F2P: dockerfile_marketplace_build_time ===
# Dockerfile.worker should `claude plugin marketplace add` and
# `claude plugin install` at build time.
print("=== F2P: dockerfile_marketplace_build_time ===")
has_marketplace_add = "claude plugin marketplace add" in df
has_plugin_install = "claude plugin install" in df
print(f"  Dockerfile has `claude plugin marketplace add`: {has_marketplace_add}")
print(f"  Dockerfile has `claude plugin install`: {has_plugin_install}")
verdicts["dockerfile_marketplace_build_time"] = has_marketplace_add and has_plugin_install
print(f"  verdict: {'PASS' if verdicts['dockerfile_marketplace_build_time'] else 'FAIL'}")

# === F2P: use_agents_lazy ===
# new-ui/src/api/hooks/use-agents.ts useAgent() should call
# `api.fetchAgent(id, false)` (2nd positional arg) for lazy loading.
print("=== F2P: use_agents_lazy ===")
# Look inside useAgent (not useAgents) for fetchAgent(id, false)
m = re.search(r"export\s+function\s+useAgent\b[^{]*\{[\s\S]*?(?=^export|\Z)", ua, re.MULTILINE)
useagent_body = m.group(0) if m else ""
lazy_call = bool(re.search(r"fetchAgent\s*\(\s*id\s*,\s*false\s*\)", useagent_body))
print(f"  useAgent body found: {bool(useagent_body)}")
print(f"  fetchAgent(id, false) present: {lazy_call}")
verdicts["use_agents_lazy"] = lazy_call
print(f"  verdict: {'PASS' if verdicts['use_agents_lazy'] else 'FAIL'}")

# === P2P_REGRESSION (informational only — diagnostic/penalty only) ===
print("=== P2P (informational only) ===")
p2p = {}
p2p["p2p_entrypoint_no_marketplace"] = ("claude plugin marketplace add" not in ep
                                        and "claude plugin install" not in ep)
p2p["p2p_entrypoint_no_wts_config"] = not bool(re.search(r"\.wts/config\.json", ep))
p2p["p2p_entrypoint_mcp_not_heredoc"] = not heredoc_mcp
p2p["p2p_dockerfile_wts_build_time"] = bool(re.search(r"\.wts/config\.json", df))
p2p["p2p_entrypoint_no_static_dirs"] = not bool(re.search(
    r"mkdir\s+-p\s+[\"']?\$?\{?(SHARED_DIR|PERSONAL_DIR)?[\"']?\}?[^\n]*shared/(thoughts|memory)", ep))
for k, v in p2p.items():
    print(f"  {k}: {'PASS' if v else 'FAIL'}")

# === Compute reward (weighted-replace formula) ===
WEIGHTS = {
    "dockerfile_apt_consolidation":     0.25,
    "dockerfile_npm_pinned":            0.20,
    "entrypoint_mcp_json_jq":           0.25,
    "dockerfile_marketplace_build_time":0.15,
    "use_agents_lazy":                  0.15,
}

# No legacy "existing" reward — pure weighted-replace.
existing = 0.0
inner_weight = max(0.0, 1.0 - sum(WEIGHTS.values()))  # 0.0 since weights sum to 1.0
reward = existing * inner_weight
for gid, w in WEIGHTS.items():
    if verdicts.get(gid):
        reward += w
reward = max(0.0, min(1.0, reward))

print(f"\n=== Final reward: {reward:.4f} ===")
print(f"F2P passed: {sum(1 for v in verdicts.values() if v)}/{len(verdicts)}")

# Persist gates.json + reward
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
