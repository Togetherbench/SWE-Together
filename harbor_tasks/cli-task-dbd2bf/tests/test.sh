#!/usr/bin/env bash
# Source-grep verifier for cli-task-dbd2bf (defer external agent discovery).
#
# Why source-grep: the canonical patch is a refactor (move call site,
# extract helper, add fallback) rather than a bug fix that's covered by
# named tests. Behavioral checks target the patch's identifying landmarks
# in a way that admits multiple valid framings of the same fix while
# rejecting the buggy state.
#
# Source of truth: canonical patch at
#   data-pipeline/artifacts_cli/canonical_patches/dbd2bfe1-bc12-4d4c-be2e-e2ec6b92170f.json
#
# Discrimination check at base commit febf309b:
#   - hooks_cmd.go:31-33 has DiscoverAndRegister at function-body top level
#   - hooks_cmd.go has NO RunE on the hooks command (only AddCommand calls)
#   - hook_registry.go has NO `executeAgentHook` symbol; logic lives inline
#     in newAgentHookVerbCmdWithLogging's RunE (~70 lines)
#   - setup.go does NOT import agent/external
#   - external.go limitedWriter.Write returns the raw buf.Write result
# Buggy state scores ~0; canonical patch scores 1.0.
set +e

export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/repo/cli}"
HOOKS_CMD="$REPO/cmd/entire/cli/hooks_cmd.go"
HOOK_REG="$REPO/cmd/entire/cli/hook_registry.go"
SETUP_GO="$REPO/cmd/entire/cli/setup.go"
EXTERNAL_GO="$REPO/cmd/entire/cli/agent/external/external.go"
REWARD_FILE="/logs/verifier/reward.txt"
GATES_FILE="/logs/verifier/gates.json"

mkdir -p /logs/verifier
rm -f "$GATES_FILE"
echo "0.0" > "$REWARD_FILE"
: > "$GATES_FILE"

emit_gate() {
    local gid="$1" verdict="$2"
    printf '{"id":"%s","verdict":"%s"}\n' "$gid" "$verdict" >> "$GATES_FILE"
}

# Sanity: all four source files must exist
for f in "$HOOKS_CMD" "$HOOK_REG" "$SETUP_GO" "$EXTERNAL_GO"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found" >&2
        # Emit all gates as fail and write reward 0.0
        for gid in g1_no_eager_discovery g2_hooks_runE g3_executeAgentHook_extracted g4_thin_verb_runE g5_setup_imports_external g6_limitedwriter_err_check; do
            emit_gate "$gid" "fail"
        done
        echo "0.0" > "$REWARD_FILE"
        exit 0
    fi
done

# ── G1 (0.25): no eager DiscoverAndRegister at newHooksCmd function-body top level ──
# Buggy: newHooksCmd contains `external.DiscoverAndRegister(discoveryCtx)` directly
# in the function body (outside any closure), so it runs on every CLI invocation.
# Pass condition: extract the body of newHooksCmd via brace-balancing and verify
# DiscoverAndRegister, if present, only appears INSIDE a RunE/anonymous-func nesting,
# not at the top level of the function. We approximate "top level" as: lines
# whose nesting depth (relative to the outer func) is == 1.
g1=0
g1_out=$(python3 - <<'PYEOF' "$HOOKS_CMD"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+newHooksCmd\s*\([^)]*\)\s*\*cobra\.Command\s*\{', src)
if not m:
    print("FAIL"); sys.exit(0)
i = m.end() - 1
depth = 0; end = -1; in_str = False; str_ch = ''
in_line = False; in_block = False
j = i
while j < len(src):
    c = src[j]; nxt = src[j+1] if j+1 < len(src) else ''
    if in_line:
        if c == '\n': in_line = False
    elif in_block:
        if c == '*' and nxt == '/':
            in_block = False; j += 2; continue
    elif in_str:
        if c == '\\': j += 2; continue
        if c == str_ch: in_str = False
    else:
        if c == '/' and nxt == '/': in_line = True
        elif c == '/' and nxt == '*':
            in_block = True; j += 2; continue
        elif c in ('"', '`', "'"): in_str = True; str_ch = c
        elif c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: end = j; break
    j += 1
if end < 0:
    print("FAIL"); sys.exit(0)
body = src[i+1:end]
depth = 0; in_str = False; str_ch = ''
in_line = False; in_block = False
top = 0
k = 0
while k < len(body):
    c = body[k]; nxt = body[k+1] if k+1 < len(body) else ''
    if in_line:
        if c == '\n': in_line = False
        k += 1; continue
    if in_block:
        if c == '*' and nxt == '/': in_block = False; k += 2; continue
        k += 1; continue
    if in_str:
        if c == '\\': k += 2; continue
        if c == str_ch: in_str = False
        k += 1; continue
    if c == '/' and nxt == '/': in_line = True; k += 2; continue
    if c == '/' and nxt == '*': in_block = True; k += 2; continue
    if c in ('"', '`', "'"): in_str = True; str_ch = c; k += 1; continue
    if c == '{': depth += 1; k += 1; continue
    if c == '}': depth -= 1; k += 1; continue
    if body[k:].startswith('DiscoverAndRegister'):
        if depth == 0: top += 1
        k += len('DiscoverAndRegister'); continue
    k += 1
print("PASS" if top == 0 else "FAIL")
PYEOF
)
if [ "$g1_out" = "PASS" ]; then g1=1; fi
if [ "$g1" = "1" ]; then emit_gate "g1_no_eager_discovery" "pass"; else emit_gate "g1_no_eager_discovery" "fail"; fi

# ── G2 (0.20): hooks command has Args: ArbitraryArgs and a RunE handler ──
# Canonical patch adds these two fields to the cobra.Command literal returned by
# newHooksCmd, enabling Cobra's RunE-fallback on unmatched subcommands.
g2=0
g2_out=$(python3 - <<'PYEOF' "$HOOKS_CMD"
import re, sys
src = open(sys.argv[1]).read()
# Find newHooksCmd body bounds
m = re.search(r'func\s+newHooksCmd\s*\([^)]*\)\s*\*cobra\.Command\s*\{', src)
if not m:
    print("FAIL"); sys.exit(0)
i = m.end() - 1
depth = 0; end = -1
j = i
while j < len(src):
    c = src[j]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: end = j; break
    j += 1
if end < 0:
    print("FAIL"); sys.exit(0)
body = src[i+1:end]
has_args = bool(re.search(r'Args\s*:\s*cobra\.ArbitraryArgs', body))
has_runE = bool(re.search(r'\bRunE\s*:\s*func\s*\(', body))
print("PASS" if (has_args and has_runE) else f"FAIL args={has_args} runE={has_runE}")
PYEOF
)
if [[ "$g2_out" == PASS* ]]; then g2=1; fi
if [ "$g2" = "1" ]; then emit_gate "g2_hooks_runE" "pass"; else emit_gate "g2_hooks_runE" "fail"; fi

# ── G3 (0.20): executeAgentHook helper extracted in hook_registry.go ──
# Canonical: a top-level `func executeAgentHook(...)` containing the previous
# inline RunE logic (worktree check, IsEnabled check, ParseHookEvent,
# DispatchLifecycleEvent). Anti-stub: function body must reference at least 3
# of {WorktreeRoot, IsEnabled, ParseHookEvent, DispatchLifecycleEvent,
# currentHookAgentName} so a 1-line stub doesn't pass.
# Alternative-fix tolerance: accept any helper name that contains
# `executeAgentHook` OR a function whose body delegates to one of those calls
# AND is referenced from the verb-cmd RunE.
g3=0
g3_out=$(python3 - <<'PYEOF' "$HOOK_REG"
import re, sys
src = open(sys.argv[1]).read()
# Find a function declaration whose name contains "executeAgentHook"
fn_re = re.compile(r'func\s+(executeAgentHook[A-Za-z0-9_]*)\s*\(([^)]*)\)\s*\w*\s*\{')
m = fn_re.search(src)
if not m:
    print("FAIL: no executeAgentHook function")
    sys.exit(0)
i = m.end() - 1
depth = 0; end = -1
j = i
while j < len(src):
    c = src[j]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: end = j; break
    j += 1
if end < 0:
    print("FAIL: function body open"); sys.exit(0)
body = src[i+1:end]
# Anti-stub markers
markers = ['WorktreeRoot', 'IsEnabled', 'ParseHookEvent',
           'DispatchLifecycleEvent', 'currentHookAgentName']
hits = sum(1 for mk in markers if mk in body)
# Substantive statements: count lines containing := or = or func calls
substantive = len([l for l in body.splitlines()
                   if re.search(r':=|\bif\b|\breturn\b|\(.*\)', l.strip())
                   and not l.strip().startswith('//')])
ok = (hits >= 3 and substantive >= 3)
print(f"PASS hits={hits} substantive={substantive}" if ok
      else f"FAIL hits={hits} substantive={substantive}")
PYEOF
)
if [[ "$g3_out" == PASS* ]]; then g3=1; fi
if [ "$g3" = "1" ]; then emit_gate "g3_executeAgentHook_extracted" "pass"; else emit_gate "g3_executeAgentHook_extracted" "fail"; fi

# ── G4 (0.10): newAgentHookVerbCmdWithLogging RunE is now thin ──
# Buggy: ~60 substantive lines inline. Canonical: RunE is a 1-line delegation
# to executeAgentHook(...). Allow up to 8 substantive lines so reasonable
# alt-fix shapes (small wrapper with a logging hook) still pass.
g4=0
g4_out=$(python3 - <<'PYEOF' "$HOOK_REG"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+newAgentHookVerbCmdWithLogging\s*\(', src)
if not m:
    print("FAIL: no newAgentHookVerbCmdWithLogging")
    sys.exit(0)
# Locate the RunE inside this function: find the next "RunE: func(" after m.start()
rune_m = re.search(r'\bRunE\s*:\s*func\s*\([^)]*\)\s*error\s*\{',
                   src[m.start():])
if not rune_m:
    print("FAIL: no RunE inside fn")
    sys.exit(0)
# Compute absolute index of the opening brace of the RunE body
abs_open = m.start() + rune_m.end() - 1
depth = 0; end = -1
j = abs_open
while j < len(src):
    c = src[j]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: end = j; break
    j += 1
if end < 0:
    print("FAIL: RunE body open"); sys.exit(0)
body = src[abs_open+1:end]
# Count substantive non-comment, non-blank lines
substantive = 0
for line in body.splitlines():
    s = line.strip()
    if not s or s.startswith('//') or s in ('{', '}'):
        continue
    substantive += 1
ok = substantive <= 8
# Additionally require the RunE body to invoke a helper (has an identifier+'(')
# so an empty placeholder doesn't pass.
calls_helper = bool(re.search(r'\b[A-Za-z_][A-Za-z0-9_]*\s*\(', body))
print(f"PASS substantive={substantive}" if (ok and calls_helper)
      else f"FAIL substantive={substantive} calls={calls_helper}")
PYEOF
)
if [[ "$g4_out" == PASS* ]]; then g4=1; fi
if [ "$g4" = "1" ]; then emit_gate "g4_thin_verb_runE" "pass"; else emit_gate "g4_thin_verb_runE" "fail"; fi

# ── G5 (0.15): setup.go imports agent/external and calls DiscoverAndRegister ──
# Canonical: the `enable` flow is updated to discover externals (so they appear
# in agent selection). Either the function-call landmark or just the import
# alone is treated as a partial; require BOTH for full credit.
g5=0
imports_external=0
calls_discover=0
if grep -qE '"github\.com/entireio/cli/cmd/entire/cli/agent/external"' "$SETUP_GO"; then
    imports_external=1
fi
if grep -qE '\bexternal\.DiscoverAndRegister\b' "$SETUP_GO"; then
    calls_discover=1
fi
if [ "$imports_external" = "1" ] && [ "$calls_discover" = "1" ]; then
    g5=1
fi
if [ "$g5" = "1" ]; then emit_gate "g5_setup_imports_external" "pass"; else emit_gate "g5_setup_imports_external" "fail"; fi

# ── G6 (0.10): limitedWriter.Write wraps buf.Write error ──
# Canonical: the trailing `return w.buf.Write(p)` is replaced with
#   n, err := w.buf.Write(p); if err != nil { return n, fmt.Errorf(...); }
#   return n, nil
# We only require evidence of the error-wrap pattern within limitedWriter.Write.
g6=0
g6_out=$(python3 - <<'PYEOF' "$EXTERNAL_GO"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'func\s+\(\s*\w+\s+\*limitedWriter\s*\)\s+Write\s*\(', src)
if not m:
    print("FAIL: limitedWriter.Write not found")
    sys.exit(0)
# Find body
brace = src.find('{', m.end())
if brace < 0: print("FAIL"); sys.exit(0)
depth = 0; end = -1
j = brace
while j < len(src):
    c = src[j]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: end = j; break
    j += 1
if end < 0: print("FAIL"); sys.exit(0)
body = src[brace+1:end]
# Look for the error-wrap pattern: an `err != nil` near a buf.Write call.
buf_write = bool(re.search(r'\bw\.buf\.Write\s*\(', body))
err_check = bool(re.search(r'\berr\s*!=\s*nil\b', body))
fmt_errorf = bool(re.search(r'fmt\.Errorf\s*\(', body))
ok = buf_write and err_check and fmt_errorf
print("PASS" if ok else f"FAIL buf={buf_write} err={err_check} fmt={fmt_errorf}")
PYEOF
)
if [[ "$g6_out" == PASS* ]]; then g6=1; fi
if [ "$g6" = "1" ]; then emit_gate "g6_limitedwriter_err_check" "pass"; else emit_gate "g6_limitedwriter_err_check" "fail"; fi

# ── Compute reward (weighted-replace, never additive) ───────────────────────
python3 - <<'PYEOF'
import json

with open("/logs/verifier/gates.json") as f:
    verdicts = {}
    for line in f:
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        verdicts[d["id"]] = d["verdict"]

weights = {
    "g1_no_eager_discovery":          0.25,
    "g2_hooks_runE":                  0.20,
    "g3_executeAgentHook_extracted":  0.20,
    "g4_thin_verb_runE":              0.10,
    "g5_setup_imports_external":      0.15,
    "g6_limitedwriter_err_check":     0.10,
}
# Σ = 1.00 → inner_weight = 0, reward = sum(passed weights)

# P2P_REGRESSION: none. P2P diagnostics do not affect reward directly.
p2p_failed = False
existing = 0.0

f2p_any_pass = any(verdicts.get(g) == "pass" for g in weights)

if p2p_failed or (not f2p_any_pass and existing <= 0):
    reward = 0.0
else:
    inner_weight = max(0.0, 1.0 - sum(weights.values()))
    reward = existing * inner_weight
    for gid, w in weights.items():
        if verdicts.get(gid) == "pass":
            reward += float(w)

reward = max(0.0, min(1.0, reward))
with open("/logs/verifier/reward.txt", "w") as f:
    f.write(f"{reward:.4f}\n")
passed = sum(1 for g in weights if verdicts.get(g) == "pass")
print(f"[eval] reward={reward:.4f}  gates_passed={passed}/{len(weights)}")
PYEOF

cat "$REWARD_FILE"
