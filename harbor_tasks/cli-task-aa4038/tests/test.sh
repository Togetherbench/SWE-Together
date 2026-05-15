#!/usr/bin/env bash
# Verifier — cli-task-aa4038: Persist transcript path into checkpoint metadata
# and use it to restore the transcript file to the correct per-agent location.
#
# Canonical patch (entireio/cli @ ef4d2e38, parent 1b69ae14) touches 5 files:
#   * cmd/entire/cli/checkpoint/checkpoint.go
#       - WriteCommittedOptions gains SessionTranscriptPath
#       - CommittedMetadata gains TranscriptPath (JSON tag transcript_path)
#   * cmd/entire/cli/checkpoint/committed.go
#       - writeSessionToSubdirectory threads SessionTranscriptPath into the
#         metadata it persists (TranscriptPath: opts.SessionTranscriptPath)
#   * cmd/entire/cli/strategy/common.go
#       - new helper homeRelativePath(absPath) using os.UserHomeDir()
#   * cmd/entire/cli/strategy/manual_commit_condensation.go
#       - CondenseSession passes homeRelativePath(state.TranscriptPath) into
#         the write call
#   * cmd/entire/cli/strategy/manual_commit_rewind.go
#       - RestoreLogsOnly + classifySessionsForRestore prefer the transcript
#         path from content.Metadata (with HOME expansion) before falling back
#         to per-agent dir resolution
#
# Six F2P behavioral/structural gates (sum 1.00) + 1 informational
# P2P_REGRESSION (go build of the touched packages). Reward formula is the
# canonical weighted-replace per CLAUDE.md.
set +e

# E2B's commands.run(envs=None) strips Dockerfile ENV PATH — hardcode every install location
export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/workspace/cli}"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"
mkdir -p "$LOGS_DIR"

CHECKPOINT_GO="$REPO/cmd/entire/cli/checkpoint/checkpoint.go"
COMMITTED_GO="$REPO/cmd/entire/cli/checkpoint/committed.go"
COMMON_GO="$REPO/cmd/entire/cli/strategy/common.go"
CONDENSE_GO="$REPO/cmd/entire/cli/strategy/manual_commit_condensation.go"
REWIND_GO="$REPO/cmd/entire/cli/strategy/manual_commit_rewind.go"

cd "$REPO" || { echo "ERROR: cd $REPO" >&2; echo 0.0 > "$REWARD_FILE"; exit 1; }

# Sanity: all five source files must exist
for f in "$CHECKPOINT_GO" "$COMMITTED_GO" "$COMMON_GO" "$CONDENSE_GO" "$REWIND_GO"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found" >&2
        echo 0.0 > "$REWARD_FILE"
        exit 0
    fi
done

# strip_go_comments path: read file → drop // line comments and /* … */ block
# comments → write to $1.stripped (so grep doesn't fire on commented-out
# scaffolding). Behavioral checks below operate on the stripped copies.
strip_go_comments() {
    local src="$1"
    local out="${src}.stripped"
    python3 - "$src" "$out" <<'PYEOF'
import re, sys
src_path, out_path = sys.argv[1], sys.argv[2]
with open(src_path, "r", encoding="utf-8", errors="replace") as f:
    s = f.read()
# Drop /* ... */ block comments (non-greedy, multiline) — Go allows nested,
# but the canonical patch doesn't rely on nesting so a simple regex is fine.
s = re.sub(r"/\*.*?\*/", "", s, flags=re.DOTALL)
# Drop // line comments. Note: this is approximate — it doesn't preserve
# string literals containing "//", but no string in these files has the
# patterns we're looking for embedded inside it.
s = re.sub(r"//[^\n]*", "", s)
with open(out_path, "w", encoding="utf-8") as f:
    f.write(s)
PYEOF
}

for f in "$CHECKPOINT_GO" "$COMMITTED_GO" "$COMMON_GO" "$CONDENSE_GO" "$REWIND_GO"; do
    strip_go_comments "$f"
done

# ──────────────────────────────────────────────────────────────────────────────
# G1 (F2P_METADATA_TRANSCRIPT_FIELD, weight 0.20)
#
# CommittedMetadata struct in checkpoint.go gains a JSON-tagged transcript
# path field. The canonical name is `TranscriptPath string `json:"transcript_path"``.
# Behavioral: any field in the CommittedMetadata struct whose JSON tag is
# `transcript_path` (with or without `,omitempty`) passes.
#
# Implementation-agnostic: we only require the JSON tag; the Go field name
# can be anything the agent picks (TranscriptPath, SessionTranscript, etc.).
# ──────────────────────────────────────────────────────────────────────────────
G1_RES=$(python3 - "$CHECKPOINT_GO.stripped" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Locate `type CommittedMetadata struct {` … matching close brace.
m = re.search(r"type\s+CommittedMetadata\s+struct\s*\{", src)
if not m:
    print("FAIL: CommittedMetadata not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == "{": depth += 1
    elif src[i] == "}": depth -= 1
    i += 1
body = src[m.end():i-1]
# Search for any field with json tag transcript_path (with or without omitempty).
# Field shape: `Name Type `json:"transcript_path[,...]" ...``.
if re.search(r'`[^`]*json:"transcript_path(?:,[^"]*)?"', body):
    print("PASS")
else:
    print("FAIL: no field with json tag transcript_path in CommittedMetadata")
PYEOF
)
G1_PASS=$([ "${G1_RES%%:*}" = "PASS" ] && echo true || echo false)
echo "[gate] F2P_METADATA_TRANSCRIPT_FIELD: $G1_RES → $G1_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G2 (F2P_OPTIONS_SESSION_TRANSCRIPT, weight 0.20)
#
# WriteCommittedOptions struct gains a NEW transcript-path field beyond the
# pre-existing TranscriptPath and SubagentTranscriptPath. The canonical name
# is `SessionTranscriptPath string`.
#
# Behavioral: any *new* string field in WriteCommittedOptions whose name
# contains "Transcript" and "Path" but is not TranscriptPath /
# SubagentTranscriptPath. The agent could reasonably pick names like
# SessionTranscriptPath, MetadataTranscriptPath, PersistTranscriptPath, etc.
# ──────────────────────────────────────────────────────────────────────────────
G2_RES=$(python3 - "$CHECKPOINT_GO.stripped" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"type\s+WriteCommittedOptions\s+struct\s*\{", src)
if not m:
    print("FAIL: WriteCommittedOptions not found"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == "{": depth += 1
    elif src[i] == "}": depth -= 1
    i += 1
body = src[m.end():i-1]
# Find fields like `Name string` (or with backtick tags). We want a name that
# contains both "Transcript" and "Path" and is NOT one of the two existing
# names already present in the buggy baseline.
existing = {"TranscriptPath", "SubagentTranscriptPath"}
found = []
for fm in re.finditer(r"^\s*([A-Z][A-Za-z0-9_]*)\s+string\b", body, re.MULTILINE):
    name = fm.group(1)
    if "Transcript" in name and "Path" in name and name not in existing:
        found.append(name)
if found:
    print(f"PASS: new field(s) {found}")
else:
    print("FAIL: no new *Transcript*Path* string field in WriteCommittedOptions")
PYEOF
)
G2_PASS=$([ "${G2_RES%%:*}" = "PASS" ] && echo true || echo false)
echo "[gate] F2P_OPTIONS_SESSION_TRANSCRIPT: $G2_RES → $G2_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G3 (F2P_HOME_RELATIVE_HELPER, weight 0.20)
#
# strategy/common.go gains a helper that strips $HOME from an absolute path
# (the canonical name is `homeRelativePath`). Behavioral signal: ANY new
# function in common.go that calls os.UserHomeDir() and returns a string.
# ──────────────────────────────────────────────────────────────────────────────
G3_RES=$(python3 - "$COMMON_GO.stripped" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Find every top-level func declaration; for each, check whether the body
# calls os.UserHomeDir(). The buggy baseline has zero such functions in
# strategy/common.go (verified at parent commit 1b69ae14).
pattern = re.compile(
    r"^func\s+(?:\([^)]*\)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*[^{]*\{",
    re.MULTILINE,
)
hits = []
for fm in pattern.finditer(src):
    name = fm.group(1)
    body_start = fm.end()
    depth = 1
    j = body_start
    while j < len(src) and depth > 0:
        if src[j] == "{": depth += 1
        elif src[j] == "}": depth -= 1
        j += 1
    body = src[body_start:j-1]
    if "os.UserHomeDir" in body:
        hits.append(name)
if hits:
    print(f"PASS: helper(s) using UserHomeDir = {hits}")
else:
    print("FAIL: no function in strategy/common.go calls os.UserHomeDir()")
PYEOF
)
G3_PASS=$([ "${G3_RES%%:*}" = "PASS" ] && echo true || echo false)
echo "[gate] F2P_HOME_RELATIVE_HELPER: $G3_RES → $G3_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G4 (F2P_COMMITTED_WRITES_TRANSCRIPT, weight 0.10)
#
# committed.go writeSessionToSubdirectory now copies the new options field
# into the persisted CommittedMetadata. Behavioral: in the assignment block
# building sessionMetadata (the function we already located the field of in
# G1), the LHS field with json tag transcript_path is assigned from
# opts.<something containing Transcript and Path>.
#
# Easier signal: check that committed.go contains a literal mention of an
# opts. field named *Transcript*Path* that is NOT TranscriptPath /
# SubagentTranscriptPath, used as an assignment value. Implementation-
# agnostic on the LHS field name.
# ──────────────────────────────────────────────────────────────────────────────
G4_RES=$(python3 - "$COMMITTED_GO.stripped" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Find every reference to opts.<Name>, filter for new transcript-path names.
existing = {"TranscriptPath", "SubagentTranscriptPath"}
names = set()
for fm in re.finditer(r"\bopts\.([A-Z][A-Za-z0-9_]*)", src):
    name = fm.group(1)
    if "Transcript" in name and "Path" in name and name not in existing:
        names.add(name)
if not names:
    print("FAIL: no new opts.*Transcript*Path* reference in committed.go")
    sys.exit(0)
# Now require at least one of those references to appear on the RHS of an
# assignment inside writeSessionToSubdirectory (where sessionMetadata is built).
# Simpler proxy: search for `:` followed by `opts.<name>` somewhere in the file.
hit = False
for n in names:
    if re.search(r":\s+opts\." + re.escape(n) + r"\b", src):
        hit = True
        break
if hit:
    print(f"PASS: committed.go assigns opts.{sorted(names)} into metadata")
else:
    print(f"FAIL: opts.{sorted(names)} present but not assigned with `: opts.<name>` syntax")
PYEOF
)
G4_PASS=$([ "${G4_RES%%:*}" = "PASS" ] && echo true || echo false)
echo "[gate] F2P_COMMITTED_WRITES_TRANSCRIPT: $G4_RES → $G4_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G5 (F2P_CONDENSE_PASSES_TRANSCRIPT, weight 0.15)
#
# manual_commit_condensation.go's CondenseSession now passes a transcript-path
# value into the write call. Behavioral signal: the file references the same
# new options field name we found in G2 (i.e. the canonical SessionTranscriptPath
# OR whatever the agent named it). Because the agent's field name must be
# consistent across files, this gate cross-validates G2.
#
# Practical check: at least one occurrence of the new field name from G2
# (or an explicit homeRelativePath/strings.TrimPrefix-style call on
# state.TranscriptPath) appears in condensation.go.
# ──────────────────────────────────────────────────────────────────────────────
G5_RES=$(python3 - "$CONDENSE_GO.stripped" "$CHECKPOINT_GO.stripped" <<'PYEOF'
import re, sys
condense = open(sys.argv[1]).read()
checkpoint = open(sys.argv[2]).read()
# Recover the new field names from WriteCommittedOptions (mirrors G2).
m = re.search(r"type\s+WriteCommittedOptions\s+struct\s*\{", checkpoint)
new_names = set()
if m:
    i = m.end(); depth = 1
    while i < len(checkpoint) and depth > 0:
        if checkpoint[i] == "{": depth += 1
        elif checkpoint[i] == "}": depth -= 1
        i += 1
    body = checkpoint[m.end():i-1]
    existing = {"TranscriptPath", "SubagentTranscriptPath"}
    for fm in re.finditer(r"^\s*([A-Z][A-Za-z0-9_]*)\s+string\b", body, re.MULTILINE):
        name = fm.group(1)
        if "Transcript" in name and "Path" in name and name not in existing:
            new_names.add(name)
# Pass if condensation.go uses any of the new field names as a struct-literal
# field assignment (e.g. `SessionTranscriptPath: ...`).
hits = [n for n in new_names if re.search(r"\b" + re.escape(n) + r"\s*:", condense)]
if hits:
    print(f"PASS: condensation.go passes {hits}")
else:
    # Fallback: agent might inline the home-relative computation differently.
    # Accept any explicit reference to state.TranscriptPath being passed
    # somewhere AND a UserHomeDir / TrimPrefix call in this file.
    if re.search(r"state\.TranscriptPath", condense) and (
        "UserHomeDir" in condense or "TrimPrefix" in condense
    ):
        print("PASS: condensation.go inlines home-relative transcript path")
    else:
        print(f"FAIL: condensation.go does not pass new transcript-path field (looked for {sorted(new_names)})")
PYEOF
)
G5_PASS=$([ "${G5_RES%%:*}" = "PASS" ] && echo true || echo false)
echo "[gate] F2P_CONDENSE_PASSES_TRANSCRIPT: $G5_RES → $G5_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# G6 (F2P_REWIND_USES_METADATA_PATH, weight 0.15)
#
# manual_commit_rewind.go's restore-side logic now reads the transcript path
# from checkpoint metadata before falling back to agent-dir resolution.
#
# Behavioral signal: the file contains a reference to
# `content.Metadata.TranscriptPath` (or any equivalent like
# `metadata.TranscriptPath` / `meta.TranscriptPath` accessed via a struct
# literal). The buggy state has zero such references.
# Additionally, the file expands a home-relative path back to absolute via
# os.UserHomeDir or filepath.Join with home (the canonical
# resolveTranscriptPathFromMetadata helper does exactly this).
# ──────────────────────────────────────────────────────────────────────────────
G6_RES=$(python3 - "$REWIND_GO.stripped" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Signal A: read TranscriptPath off something whose name contains "Metadata"
# (common variants: content.Metadata.TranscriptPath, sessionMetadata.TranscriptPath).
sig_a = bool(re.search(
    r"\b(?:[A-Za-z_][A-Za-z0-9_]*\.)*[Mm]etadata(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.TranscriptPath\b",
    src,
))
# Signal B: home-dir expansion appears (UserHomeDir in this file, or a helper
# like resolveTranscriptPathFromMetadata that the file calls).
sig_b = ("os.UserHomeDir" in src) or ("ResolveTranscriptPath" in src) or (
    "resolveTranscriptPath" in src
) or ("expandHomePath" in src) or ("expandHome" in src)
if sig_a and sig_b:
    print("PASS: rewind reads metadata.TranscriptPath + expands $HOME")
elif sig_a:
    print("PASS: rewind reads metadata.TranscriptPath (no explicit HOME expansion in this file)")
else:
    print("FAIL: rewind does not read transcript path off metadata struct")
PYEOF
)
G6_PASS=$([ "${G6_RES%%:*}" = "PASS" ] && echo true || echo false)
echo "[gate] F2P_REWIND_USES_METADATA_PATH: $G6_RES → $G6_PASS"

# ──────────────────────────────────────────────────────────────────────────────
# P2P_REGRESSION: GO_BUILD — informational only, never positive reward.
# Per CLAUDE.md scoring rules, P2P_REGRESSION is logged for audit but does
# NOT zero the reward (`p2p_failed = false` always).
# ──────────────────────────────────────────────────────────────────────────────
BUILD_LOG="$LOGS_DIR/go_build.log"
go build ./cmd/entire/cli/checkpoint/... ./cmd/entire/cli/strategy/... > "$BUILD_LOG" 2>&1
BUILD_RC=$?
if [ "$BUILD_RC" = "0" ]; then
    P1_PASS=true
else
    P1_PASS=false
    echo "[gate] go build failed; tail of $BUILD_LOG:"
    tail -20 "$BUILD_LOG"
fi
echo "[gate] P2P_GO_BUILD (informational): rc=$BUILD_RC → $P1_PASS"

# Cleanup stripped intermediates so they aren't picked up by repo state probes
rm -f "$CHECKPOINT_GO.stripped" "$COMMITTED_GO.stripped" "$COMMON_GO.stripped" \
      "$CONDENSE_GO.stripped" "$REWIND_GO.stripped"

# ── Build gates.json (audit log; never affects reward by itself) ─────────────
python3 - "$GATES_FILE" "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" "$P1_PASS" <<'PYEOF'
import json, sys
gates_file = sys.argv[1]
f2p_verdicts = [s == "true" for s in sys.argv[2:8]]
p2p_verdicts = [s == "true" for s in sys.argv[8:9]]
f2p_ids = [
    "F2P_METADATA_TRANSCRIPT_FIELD",
    "F2P_OPTIONS_SESSION_TRANSCRIPT",
    "F2P_HOME_RELATIVE_HELPER",
    "F2P_COMMITTED_WRITES_TRANSCRIPT",
    "F2P_CONDENSE_PASSES_TRANSCRIPT",
    "F2P_REWIND_USES_METADATA_PATH",
]
p2p_ids = ["P2P_GO_BUILD"]
gates = [{"id": gid, "pass": v, "kind": "F2P"} for gid, v in zip(f2p_ids, f2p_verdicts)]
gates += [{"id": gid, "pass": v, "kind": "P2P_REGRESSION"} for gid, v in zip(p2p_ids, p2p_verdicts)]
with open(gates_file, "w") as f:
    json.dump(gates, f, indent=2)
PYEOF

# ── Weighted-replace reward formula (CLAUDE.md canonical) ────────────────────
# Sum of F2P weights = 1.00 (full replacement; legacy reward fully subsumed).
# P2P_REGRESSION is informational only.
existing="0.0"
if [ -f "$LOGS_DIR/base_reward.txt" ]; then
    existing=$(cat "$LOGS_DIR/base_reward.txt" 2>/dev/null || echo "0.0")
fi

# P2P_REGRESSION: informational only — diagnostic/penalty only
p2p_failed=false

# F2P: at least one gate must pass for non-zero reward (or existing > 0)
f2p_any_pass=false
for v in "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS"; do
    if [ "$v" = "true" ]; then
        f2p_any_pass=true
        break
    fi
done

reward=$(python3 - "$existing" "$f2p_any_pass" "$p2p_failed" \
    "$G1_PASS" "$G2_PASS" "$G3_PASS" "$G4_PASS" "$G5_PASS" "$G6_PASS" <<'PYEOF'
import sys
existing = float(sys.argv[1])
f2p_any_pass = sys.argv[2] == "true"
p2p_failed = sys.argv[3] == "true"
v = [s == "true" for s in sys.argv[4:10]]
WEIGHTS = {
    "F2P_METADATA_TRANSCRIPT_FIELD":   0.20,
    "F2P_OPTIONS_SESSION_TRANSCRIPT":  0.20,
    "F2P_HOME_RELATIVE_HELPER":        0.20,
    "F2P_COMMITTED_WRITES_TRANSCRIPT": 0.10,
    "F2P_CONDENSE_PASSES_TRANSCRIPT":  0.15,
    "F2P_REWIND_USES_METADATA_PATH":   0.15,
}
ids = list(WEIGHTS.keys())
verdicts = dict(zip(ids, v))
if p2p_failed or (not f2p_any_pass and existing <= 0):
    print("0.000000")
else:
    inner_weight = max(0.0, 1.0 - sum(WEIGHTS.values()))
    r = existing * inner_weight
    for gid, w in WEIGHTS.items():
        if verdicts.get(gid):
            r += float(w)
    r = max(0.0, min(1.0, r))
    print(f"{r:.6f}")
PYEOF
)

echo "$reward" > "$REWARD_FILE"
echo "─────────────────────────────────────────────────"
echo "Gate verdicts:"
echo "  F2P_METADATA_TRANSCRIPT_FIELD   = $G1_PASS  (weight 0.20)"
echo "  F2P_OPTIONS_SESSION_TRANSCRIPT  = $G2_PASS  (weight 0.20)"
echo "  F2P_HOME_RELATIVE_HELPER        = $G3_PASS  (weight 0.20)"
echo "  F2P_COMMITTED_WRITES_TRANSCRIPT = $G4_PASS  (weight 0.10)"
echo "  F2P_CONDENSE_PASSES_TRANSCRIPT  = $G5_PASS  (weight 0.15)"
echo "  F2P_REWIND_USES_METADATA_PATH   = $G6_PASS  (weight 0.15)"
echo "  [P2P] GO_BUILD                  = $P1_PASS  (informational only)"
echo "Final reward: $reward"
cat "$REWARD_FILE"
