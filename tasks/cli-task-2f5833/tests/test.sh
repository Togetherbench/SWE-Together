#!/usr/bin/env bash
# Behavioral verifier for cli-task-2f5833.
# Tests are grep/AST checks against the agent's source-tree changes,
# matching the gates declared in test_manifest.yaml. The original
# go-test-based scoring path is kept as a regression safety net (P2P).
set +e

export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

TASK_DIR="${TASK_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
EVAL_DIR="${EVAL_DIR:-/tests}"
mkdir -p "$LOGS_DIR"

CONFIG="$TASK_DIR/tests/install_config.json"
REPO_DIR=$(python3 -c "import json; print(json.load(open('$CONFIG'))['repo_dir'])")

cd "$REPO_DIR" || { echo "ERROR: cd $REPO_DIR" >&2; echo 0.0 > "$LOGS_DIR/reward.txt"; exit 1; }

LIFECYCLE_GO="cmd/entire/cli/lifecycle.go"
HOOKS_GO="cmd/entire/cli/strategy/manual_commit_hooks.go"
PATHS_GO="cmd/entire/cli/paths/paths.go"
AGENT_GO="cmd/entire/cli/agent/agent.go"
TYPES_GO="cmd/entire/cli/strategy/manual_commit_types.go"
STATE_GO="cmd/entire/cli/session/state.go"
INTEG_HOOKS_GO="cmd/entire/cli/integration_test/hooks.go"

python3 - "$REPO_DIR" "$LOGS_DIR" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

repo_dir, logs_dir = sys.argv[1], sys.argv[2]
os.chdir(repo_dir)


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except (FileNotFoundError, IsADirectoryError):
        return ""


def slice_func(src, name):
    """Return the body of a top-level Go function by brace-balancing.
    Looks for `func [(...)] <name>(...)` with optional receiver."""
    pat = re.compile(r"^func\s+(\([^)]*\)\s+)?" + re.escape(name) + r"\b", re.M)
    m = pat.search(src)
    if not m:
        return ""
    i = src.find("{", m.end())
    if i < 0:
        return ""
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
        j += 1
    return src[i:]


lifecycle = read("cmd/entire/cli/lifecycle.go")
hooks = read("cmd/entire/cli/strategy/manual_commit_hooks.go")
paths_go = read("cmd/entire/cli/paths/paths.go")
agent_go = read("cmd/entire/cli/agent/agent.go")
types_go = read("cmd/entire/cli/strategy/manual_commit_types.go")
state_go = read("cmd/entire/cli/session/state.go")
integ_hooks = read("cmd/entire/cli/integration_test/hooks.go")
condense_go = read("cmd/entire/cli/strategy/manual_commit_condensation.go")
cc_lifecycle = read("cmd/entire/cli/agent/claudecode/lifecycle.go")
gemini_lifecycle = read("cmd/entire/cli/agent/geminicli/lifecycle.go")
gemini_transcript = read("cmd/entire/cli/agent/geminicli/transcript.go")
opencode_transcript = read("cmd/entire/cli/agent/opencode/transcript.go")

turn_end = slice_func(lifecycle, "handleLifecycleTurnEnd")
turn_start = slice_func(lifecycle, "handleLifecycleTurnStart")
finalize_all = slice_func(hooks, "finalizeAllTurnCheckpoints")

verdicts = {}

# ── F2P Gold (0.45) ──

# G1: handleLifecycleTurnEnd does NOT call ExtractPrompts from transcript
verdicts["G1_gold_no_extract_prompts"] = bool(turn_end) and ("ExtractPrompts" not in turn_end)

# G2: finalizeAllTurnCheckpoints reads prompts from shadow branch + filesystem fallback
verdicts["G2_gold_shadow_filesystem_fallback"] = (
    bool(finalize_all)
    and "readPromptsFromShadowBranch" in finalize_all
    and "readPromptsFromFilesystem" in finalize_all
)

# G3: handleLifecycleTurnEnd does NOT overwrite prompt.txt via WriteFile
# (must not combine PromptFileName + WriteFile inside TurnEnd's body)
g3_bad = False
if turn_end:
    # find any WriteFile call whose argument list mentions PromptFileName
    for m in re.finditer(r"\bos\.WriteFile\s*\(", turn_end):
        # capture roughly the next 200 chars as the call args window
        window = turn_end[m.start() : m.start() + 400]
        if "PromptFileName" in window:
            g3_bad = True
            break
    # also forbid explicit promptFile := ...PromptFileName followed by WriteFile(promptFile,...)
    if re.search(r"promptFile\s*:?=.*PromptFileName", turn_end) and re.search(
        r"WriteFile\s*\(\s*promptFile", turn_end
    ):
        g3_bad = True
verdicts["G3_gold_no_prompt_overwrite"] = bool(turn_end) and not g3_bad

# ── F2P Silver (0.35) ──

# S1: ExtractSummary removed from TranscriptAnalyzer interface in agent.go
# Find the TranscriptAnalyzer interface block
ta_match = re.search(r"type\s+TranscriptAnalyzer\s+interface\s*\{([^}]*)\}", agent_go, re.S)
verdicts["S1_silver_no_extract_summary"] = bool(ta_match) and "ExtractSummary" not in ta_match.group(1)

# S2: SummaryFileName constant removed from paths.go
verdicts["S2_silver_no_summary_filename"] = "SummaryFileName" not in paths_go

# S3: FirstPrompt field renamed to LastPrompt in session state struct
state_struct = re.search(r"type\s+State\s+struct\s*\{([^}]*)\}", state_go, re.S)
if state_struct:
    body = state_struct.group(1)
    # require: a LastPrompt field, and no FirstPrompt field declaration
    has_last = re.search(r"^\s*LastPrompt\s+string", body, re.M) is not None
    has_first = re.search(r"^\s*FirstPrompt\s+string", body, re.M) is not None
    verdicts["S3_silver_last_prompt_field"] = has_last and not has_first
else:
    verdicts["S3_silver_last_prompt_field"] = False

# S4: TurnEnd uses LoadSessionState for commit message prompt
verdicts["S4_silver_lifecycle_commit_msg"] = (
    bool(turn_end)
    and "LoadSessionState" in turn_end
    and "LastPrompt" in turn_end
    # and the old pattern is gone
    and "allPrompts[len(allPrompts)-1]" not in turn_end
)

# ── F2P Bronze (0.20) ──

# B1: maxFirstPromptRunes renamed to maxLastPromptRunes
verdicts["B1_bronze_max_last_prompt_runes"] = (
    "maxLastPromptRunes" in types_go and "maxFirstPromptRunes" not in types_go
)

# B2: TurnStart appends event.Prompt to filesystem prompt.txt
# Look for a write inside TurnStart that uses event.Prompt + PromptFileName
b2 = False
if turn_start and "event.Prompt" in turn_start and "PromptFileName" in turn_start:
    # require either a "---" separator pattern (append-style) or ReadFile-then-WriteFile combo
    if "\\n\\n---\\n\\n" in turn_start or "---" in turn_start:
        b2 = True
    elif "ReadFile" in turn_start and "WriteFile" in turn_start:
        b2 = True
verdicts["B2_bronze_turn_start_append"] = b2

# B3: ExtractSummary implementations removed from claudecode, geminicli, opencode agents
# We verify no `func (... ) ExtractSummary(` exists in the three files.
b3 = True
for src in (cc_lifecycle, gemini_lifecycle, gemini_transcript, opencode_transcript):
    if re.search(r"func\s*\([^)]*\)\s+ExtractSummary\s*\(", src):
        b3 = False
        break
verdicts["B3_bronze_agent_summary_removed"] = b3

# B4: SimulateUserPromptSubmitWithPrompt test helper added to hooks.go
verdicts["B4_bronze_simulate_prompt_helpers"] = "SimulateUserPromptSubmitWithPrompt" in integ_hooks

WEIGHTS = {
    "G1_gold_no_extract_prompts": 0.15,
    "G2_gold_shadow_filesystem_fallback": 0.15,
    "G3_gold_no_prompt_overwrite": 0.15,
    "S1_silver_no_extract_summary": 0.10,
    "S2_silver_no_summary_filename": 0.10,
    "S3_silver_last_prompt_field": 0.05,
    "S4_silver_lifecycle_commit_msg": 0.10,
    "B1_bronze_max_last_prompt_runes": 0.05,
    "B2_bronze_turn_start_append": 0.05,
    "B3_bronze_agent_summary_removed": 0.05,
    "B4_bronze_simulate_prompt_helpers": 0.05,
}

# ── P2P Regression (informational) ──
# Try `go build ./...`. If build is broken, log a warning but do NOT
# zero the reward — keep diagnostic informational per repo convention
# (see CLAUDE.md: P2P_REGRESSION gates are informational only).
gates_log = {"verdicts": dict(verdicts)}
build_ok = None
try:
    res = subprocess.run(
        ["go", "build", "./..."],
        cwd=repo_dir,
        capture_output=True,
        text=True,
        timeout=90,
    )
    build_ok = res.returncode == 0
    gates_log["P2P1_build"] = {"ok": build_ok, "stderr_tail": res.stderr[-500:]}
except Exception as exc:
    gates_log["P2P1_build"] = {"ok": None, "error": str(exc)}

# Score: weighted-replace formula. Any inner reward is implicit (no legacy
# numeric reward exists for this task — it was overall-pass-rate-based).
# Treat existing as 0; reward = sum(passed_weights).
f2p_any_pass = any(verdicts.values())
inner_share = max(0.0, 1.0 - sum(WEIGHTS.values()))  # 0.0 here (Σ = 1.0)
existing = 0.0
if not f2p_any_pass and existing <= 0:
    reward = 0.0
else:
    reward = existing * inner_share
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)

reward = max(0.0, min(1.0, reward))
gates_log["reward"] = reward
gates_log["weights_passed"] = sum(w for gid, w in WEIGHTS.items() if verdicts.get(gid))

with open(os.path.join(logs_dir, "gates.json"), "w") as f:
    json.dump(gates_log, f, indent=2, default=str)

with open(os.path.join(logs_dir, "reward.txt"), "w") as f:
    f.write(f"{reward:.6f}\n")

print(f"[eval] reward={reward:.4f}")
print("[eval] verdicts:")
for gid, w in WEIGHTS.items():
    mark = "PASS" if verdicts.get(gid) else "FAIL"
    print(f"  {mark}  {gid:40s}  weight={w:.2f}")
if build_ok is False:
    print("[eval] WARNING: go build failed (informational, not diagnostic)")
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
