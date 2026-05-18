#!/usr/bin/env bash
# Verifier — cli-task-4a9dde: make Gemini E2E test runner non-interactive
# (entireio/cli @ 19cca30).
#
# Canonical patch (data-pipeline/artifacts_cli/canonical_patches/
#   4a9dde92-9a32-4a2f-ae0b-c9f6e026cd16.json) makes 3 distinct fixes to stop
# `mise run test:e2e:gemini` from hanging:
#
#   1. e2e_test/agent_runner.go — Gemini runner switches from
#      `--approval-mode auto_edit --allowed-tools …` to `--approval-mode yolo`,
#      sets ENTIRE_TEST_TTY=1 in the subprocess env, and pipes /dev/null to
#      stdin so any stray prompt can't block.
#   2. strategy/manual_commit_hooks.go — `hasTTY()` and `askConfirmTTY()` short
#      circuit on `GEMINI_CLI` env var (Gemini sets it inside ShellTool
#      subprocesses; without this the prepare-commit-msg hook hangs reading
#      /dev/tty).
#   3. strategy/content_overlap.go — `filesWithRemainingAgentChanges` skips
#      carry-forward when a file is already in HEAD with hash matching the
#      shadow branch (uses commitTree.File / shadowTree.File hash compare).
#
# Each gate writes a JSON verdict to /logs/verifier/gates.json; reward is
# weighted-replace per CLAUDE.md (sum F2P weights = 1.00; P2P_REGRESSION
# informational only).
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/opt/entire-cli}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

AGENT_RUNNER="cmd/entire/cli/e2e_test/agent_runner.go"
HOOKS_GO="cmd/entire/cli/strategy/manual_commit_hooks.go"
OVERLAP_GO="cmd/entire/cli/strategy/content_overlap.go"

# Sanity: source files exist (P2P regression — informational only)
P2P_FILES_OK=true
[ -f "$AGENT_RUNNER" ] || P2P_FILES_OK=false
[ -f "$HOOKS_GO"     ] || P2P_FILES_OK=false
[ -f "$OVERLAP_GO"   ] || P2P_FILES_OK=false

# ──────────────────────────────────────────────────────────────────────────────
# Gate 1 (F2P_GEMINI_YOLO_MODE, weight 0.20):
#   GeminiCLIRunner.RunPromptWithTools uses --approval-mode yolo. Anti-pattern:
#   the buggy state hard-codes --approval-mode auto_edit and a long
#   --allowed-tools list. Implementation-agnostic: any solution that switches
#   approval to yolo (Gemini's "auto-approve everything" mode for tests in
#   isolated dirs) qualifies.
# ──────────────────────────────────────────────────────────────────────────────
G1_PASS=false
G1_RES="missing"
if [ -f "$AGENT_RUNNER" ]; then
    G1_RES=$(python3 - "$AGENT_RUNNER" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+\(r\s+\*GeminiCLIRunner\)\s+RunPromptWithTools\s*\([^)]*\)\s*\([^)]*\)\s*\{', src)
if not m:
    print("FAIL: RunPromptWithTools not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]
body_nc = re.sub(r'//[^\n]*', '', body)
body_nc = re.sub(r'/\*.*?\*/', '', body_nc, flags=re.DOTALL)
# Must select yolo as the approval mode somewhere in the function (active code).
yolo = bool(re.search(r'"yolo"', body_nc))
# Must NOT still pin --approval-mode to auto_edit (in active code).
auto_edit = bool(re.search(r'"auto_edit"', body_nc))
ok = yolo and not auto_edit
print(f"yolo={yolo} auto_edit={auto_edit} -> {'PASS' if ok else 'FAIL'}")
PYEOF
)
    [[ "$G1_RES" == *PASS ]] && G1_PASS=true
fi
echo "[G1_GEMINI_YOLO_MODE] $G1_RES pass=$G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 2 (F2P_GEMINI_RUNNER_TTY_GUARDS, weight 0.20):
#   Inside Gemini RunPromptWithTools, ≥2 of 3 hang-prevention guards land:
#     (a) ENTIRE_TEST_TTY=1 added to subprocess env (so manual_commit_hooks
#         hasTTY() returns true under test, stops hook from probing /dev/tty)
#     (b) /dev/null (os.DevNull) attached to stdin
#     (c) cmd.Env explicitly set (regardless of contents) — separate marker
#         that the runner stopped inheriting the parent env wholesale
#   2-of-3 admits partial fixes (e.g., only env var, only stdin redirect).
# ──────────────────────────────────────────────────────────────────────────────
G2_PASS=false
G2_RES="missing"
if [ -f "$AGENT_RUNNER" ]; then
    G2_RES=$(python3 - "$AGENT_RUNNER" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+\(r\s+\*GeminiCLIRunner\)\s+RunPromptWithTools\s*\([^)]*\)\s*\([^)]*\)\s*\{', src)
if not m:
    print("FAIL: RunPromptWithTools not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]
test_tty = bool(re.search(r'ENTIRE_TEST_TTY[^"]*"\s*,?\s*"?1"?|ENTIRE_TEST_TTY=1', body))
dev_null = ('os.DevNull' in body) or bool(re.search(r'/dev/null', body))
cmd_env = bool(re.search(r'cmd\.Env\s*=', body))
hits = sum([test_tty, dev_null, cmd_env])
print(f"test_tty={test_tty} dev_null={dev_null} cmd_env={cmd_env} hits={hits} -> {'PASS' if hits >= 2 else 'FAIL'}")
PYEOF
)
    [[ "$G2_RES" == *PASS ]] && G2_PASS=true
fi
echo "[G2_GEMINI_RUNNER_TTY_GUARDS] $G2_RES pass=$G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 3 (F2P_HASTTY_GEMINI_GUARD, weight 0.20):
#   manual_commit_hooks.go::hasTTY() returns false (or short-circuits) when
#   GEMINI_CLI env var is set. Implementation-agnostic: we check that hasTTY's
#   body references GEMINI_CLI. Buggy state has no such reference.
# ──────────────────────────────────────────────────────────────────────────────
G3_PASS=false
G3_RES="missing"
if [ -f "$HOOKS_GO" ]; then
    G3_RES=$(python3 - "$HOOKS_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+hasTTY\s*\(\s*\)\s*bool\s*\{', src)
if not m:
    print("FAIL: hasTTY not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]
has_gemini = 'GEMINI_CLI' in body
print(f"GEMINI_CLI_in_hasTTY={has_gemini} -> {'PASS' if has_gemini else 'FAIL'}")
PYEOF
)
    [[ "$G3_RES" == *PASS ]] && G3_PASS=true
fi
echo "[G3_HASTTY_GEMINI_GUARD] $G3_RES pass=$G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 4 (F2P_ASKCONFIRM_GEMINI_GUARD, weight 0.15):
#   manual_commit_hooks.go::askConfirmTTY() also short-circuits when GEMINI_CLI
#   is set (returns the default rather than blocking on /dev/tty read). Buggy
#   state has no such guard.
# ──────────────────────────────────────────────────────────────────────────────
G4_PASS=false
G4_RES="missing"
if [ -f "$HOOKS_GO" ]; then
    G4_RES=$(python3 - "$HOOKS_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+askConfirmTTY\s*\([^)]*\)\s*bool\s*\{', src)
if not m:
    print("FAIL: askConfirmTTY not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]
has_gemini = 'GEMINI_CLI' in body
print(f"GEMINI_CLI_in_askConfirmTTY={has_gemini} -> {'PASS' if has_gemini else 'FAIL'}")
PYEOF
)
    [[ "$G4_RES" == *PASS ]] && G4_PASS=true
fi
echo "[G4_ASKCONFIRM_GEMINI_GUARD] $G4_RES pass=$G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 5 (F2P_OVERLAP_HEAD_HASH_CHECK, weight 0.15):
#   content_overlap.go::filesWithRemainingAgentChanges short-circuits when a
#   file already exists in HEAD (commit tree) with content matching the shadow
#   branch — i.e. it was fully committed by a prior commit and shouldn't be
#   carried forward again. Buggy state simply appends to `remaining` whenever
#   `wasCommitted` is false.
#
#   Concept coverage (≥3 of 4 markers in the unCommitted-file branch):
#     * `commitTree.File(` invocation (or `commitTree.File`/`headFile, ` capture)
#     * `shadowTree.File(` invocation
#     * Hash comparison expression (`.Hash == ` or `Hash !=` between the two)
#     * A `continue` exit (i.e. don't add to `remaining`) inside the new branch
# ──────────────────────────────────────────────────────────────────────────────
G5_PASS=false
G5_RES="missing"
if [ -f "$OVERLAP_GO" ]; then
    G5_RES=$(python3 - "$OVERLAP_GO" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+filesWithRemainingAgentChanges\s*\(', src)
if not m:
    print("FAIL: filesWithRemainingAgentChanges not found"); sys.exit(0)
# Walk past the parameter list, balancing parens (params may be multi-line and
# contain `map[string]struct{}` literals — we can't just find the next `{`).
i = m.end(); paren_depth = 1
while i < len(src) and paren_depth > 0:
    if src[i] == '(': paren_depth += 1
    elif src[i] == ')': paren_depth -= 1
    i += 1
# Now find the opening brace of the function body (after the return type).
brace = src.find('{', i)
if brace == -1:
    print("FAIL: function body not found"); sys.exit(0)
i = brace + 1; depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[brace+1:i-1]

# Buggy state ALREADY has commitTree.File/shadowTree.File/hash compare in the
# `wasCommitted` branch (the `else` arm). The bug is that `!wasCommitted`
# unconditionally appends to `remaining`. The canonical fix adds the same
# hash-compare logic *inside* the `!wasCommitted` branch — so we must pin the
# check to that branch specifically.
m_branch = re.search(r'!\s*wasCommitted\s*\{', body)
inner = ""
if m_branch:
    j = m_branch.end(); d = 1
    while j < len(body) and d > 0:
        if body[j] == '{': d += 1
        elif body[j] == '}': d -= 1
        j += 1
    inner = body[m_branch.end():j-1]

# Inside the `!wasCommitted` branch, look for ≥3 of 4 markers signalling the
# new "is the file already in HEAD with matching shadow content?" check:
commit_tree_file = bool(re.search(r'commitTree\.File\s*\(', inner))
shadow_tree_file = bool(re.search(r'shadowTree\.File\s*\(', inner))
hash_compare = bool(re.search(r'\.Hash\s*(==|!=)\s*[A-Za-z_][A-Za-z0-9_]*\.Hash', inner))
if not hash_compare:
    hash_compare = bool(re.search(r'bytes\.Equal\s*\([^)]*Hash[^)]*Hash[^)]*\)', inner))
# A `continue` to skip carry-forward for matched-content files.
has_continue = bool(re.search(r'\bcontinue\b', inner))

hits = sum([commit_tree_file, shadow_tree_file, hash_compare, has_continue])
print(f"in_!wasCommitted_branch: commitTree.File={commit_tree_file} "
      f"shadowTree.File={shadow_tree_file} hash_compare={hash_compare} "
      f"continue={has_continue} hits={hits} -> {'PASS' if hits >= 3 else 'FAIL'}")
PYEOF
)
    [[ "$G5_RES" == *PASS ]] && G5_PASS=true
fi
echo "[G5_OVERLAP_HEAD_HASH_CHECK] $G5_RES pass=$G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# Gate 6 (F2P_NO_HARDCODED_GIT_TOOLS, weight 0.10):
#   Anti-pattern: the buggy GeminiCLIRunner hard-codes a `defaultAllowedTools`
#   slice with ShellTool(git status/add/commit/diff/log) entries — these are
#   the entries Gemini's --allowed-tools mechanism couldn't match because of
#   exact-match semantics, which was the proximate cause of the hang. After
#   the fix, none of these hard-coded ShellTool(git …) entries should remain
#   in agent_runner.go's GeminiCLIRunner.RunPromptWithTools body.
# ──────────────────────────────────────────────────────────────────────────────
G6_PASS=false
G6_RES="missing"
if [ -f "$AGENT_RUNNER" ]; then
    G6_RES=$(python3 - "$AGENT_RUNNER" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+\(r\s+\*GeminiCLIRunner\)\s+RunPromptWithTools\s*\([^)]*\)\s*\([^)]*\)\s*\{', src)
if not m:
    print("FAIL: RunPromptWithTools not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
body = src[m.end():i-1]
# Strip Go line comments and block comments so a comment that mentions the old
# pattern (e.g. "Note: --allowed-tools requires ShellTool(git add) match...")
# doesn't make the gate fail.
body_no_comments = re.sub(r'//[^\n]*', '', body)
body_no_comments = re.sub(r'/\*.*?\*/', '', body_no_comments, flags=re.DOTALL)
# How many "ShellTool(git …)" string literals remain in active code?
hits = len(re.findall(r'"ShellTool\(git\s+\w+\)"', body_no_comments))
ok = hits == 0
print(f"ShellTool_git_literals={hits} -> {'PASS' if ok else 'FAIL'}")
PYEOF
)
    [[ "$G6_RES" == *PASS ]] && G6_PASS=true
fi
echo "[G6_NO_HARDCODED_GIT_TOOLS] $G6_RES pass=$G6_PASS"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" "$P2P_FILES_OK" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
verdicts = [s == "true" for s in sys.argv[2:8]]
p2p_ok = sys.argv[8] == "true"
ids = ["F2P_GEMINI_YOLO_MODE", "F2P_GEMINI_RUNNER_TTY_GUARDS",
       "F2P_HASTTY_GEMINI_GUARD", "F2P_ASKCONFIRM_GEMINI_GUARD",
       "F2P_OVERLAP_HEAD_HASH_CHECK", "F2P_NO_HARDCODED_GIT_TOOLS"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(ids, verdicts)]
gates.append({"id": "P2P_SOURCE_FILES_EXIST", "pass": p2p_ok, "kind": "P2P_REGRESSION"})
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# F2P weight sum = 1.00 → inner_share = 0; legacy `existing` reward is fully
# subsumed (intentional). P2P_REGRESSION informational only (never zeros).
existing="0.0"
if [ -f "$LOGS_DIR/base_reward.txt" ]; then
    existing=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")
fi

reward=$(python3 - "$existing" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" <<'PYEOF'
import sys
existing = float(sys.argv[1])
v = [s == "true" for s in sys.argv[2:8]]
WEIGHTS = {
    "F2P_GEMINI_YOLO_MODE":          0.20,
    "F2P_GEMINI_RUNNER_TTY_GUARDS":  0.20,
    "F2P_HASTTY_GEMINI_GUARD":       0.20,
    "F2P_ASKCONFIRM_GEMINI_GUARD":   0.15,
    "F2P_OVERLAP_HEAD_HASH_CHECK":   0.15,
    "F2P_NO_HARDCODED_GIT_TOOLS":    0.10,
}
ids = list(WEIGHTS.keys())
verdicts = dict(zip(ids, v))
p2p_failed = False  # P2P_REGRESSION informational only
f2p_any_pass = any(verdicts.values())

if not f2p_any_pass and existing <= 0:
    reward = 0.0
else:
    inner = max(0.0, 1.0 - sum(WEIGHTS.values()))
    reward = existing * inner
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            reward += float(w)
print(f"{max(0.0, min(1.0, reward)):.6f}")
PYEOF
)

echo "$reward" > "$REWARD_FILE"
echo "─────────────────────────────────────────────────"
echo "Gate verdicts:"
echo "  F2P_GEMINI_YOLO_MODE         = $G1_PASS  (weight 0.20)"
echo "  F2P_GEMINI_RUNNER_TTY_GUARDS = $G2_PASS  (weight 0.20)"
echo "  F2P_HASTTY_GEMINI_GUARD      = $G3_PASS  (weight 0.20)"
echo "  F2P_ASKCONFIRM_GEMINI_GUARD  = $G4_PASS  (weight 0.15)"
echo "  F2P_OVERLAP_HEAD_HASH_CHECK  = $G5_PASS  (weight 0.15)"
echo "  F2P_NO_HARDCODED_GIT_TOOLS   = $G6_PASS  (weight 0.10)"
echo "  [P2P] SOURCE_FILES_EXIST     = $P2P_FILES_OK  (informational only)"
echo "Final reward: $reward"
cat "$REWARD_FILE"

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
