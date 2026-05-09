#!/usr/bin/env bash
# Behavioral verifier for light-protocol-implement-7adad1
# (Add `associated_token::idempotent` flag to `#[light_account]` macro).
#
# Cargo-based verification is intractable in E2B for this task: build scripts
# of every transitive proc-macro dep (libc, proc-macro2, quote, serde_core)
# hard-code `clang` as the linker, but the base image only ships
# build-essential (gcc), not clang. Even `cargo test -p light-sdk-macros`
# (a "small" proc-macro crate) fails at the build-script link step. This
# verifier therefore uses source-grep / AST checks against the canonical
# patched files in `sdk-libs/macros/src/light_pdas/`. Implementation-tolerant
# — accepts multiple valid framings of the same fix. Pattern mirrors
# moltis-task-ffe9ec.
set +e

export PATH="/usr/local/go/bin:/root/go/bin:/home/agent/go/bin:/usr/local/cargo/bin:/opt/cargo/bin:/root/.cargo/bin:/home/agent/.cargo/bin:/venv/bin:/opt/venv/bin:/usr/local/bin:/root/.bun/bin:/home/agent/.bun/bin:/usr/bin:/bin:${PATH}"

REPO="${REPO:-/home/user/light-protocol}"
KEYWORDS_RS="$REPO/sdk-libs/macros/src/light_pdas/light_account_keywords.rs"
ACCOUNT_RS="$REPO/sdk-libs/macros/src/light_pdas/accounts/light_account.rs"
BUILDER_RS="$REPO/sdk-libs/macros/src/light_pdas/accounts/builder.rs"
LOGS_DIR="${LOGS_DIR:-/logs/verifier}"
REWARD_FILE="$LOGS_DIR/reward.txt"
GATES_FILE="$LOGS_DIR/gates.json"

mkdir -p "$LOGS_DIR"
rm -f "$GATES_FILE"
echo "0.0" > "$REWARD_FILE"
: > "$GATES_FILE"

emit_gate() {
    local gid="$1" verdict="$2"
    printf '{"id":"%s","verdict":"%s"}\n' "$gid" "$verdict" >> "$GATES_FILE"
}

# Sanity: keywords + account files must exist (builder.rs is searched
# loosely under sdk-libs/macros/src/ in g5 — its exact path/name has shifted
# upstream and isn't required to be at the canonical location)
if [ ! -f "$KEYWORDS_RS" ] || [ ! -f "$ACCOUNT_RS" ]; then
    echo "ERROR: one or more macro source files missing" >&2
    [ ! -f "$KEYWORDS_RS" ] && echo "  missing: $KEYWORDS_RS" >&2
    [ ! -f "$ACCOUNT_RS" ] && echo "  missing: $ACCOUNT_RS" >&2
    exit 0
fi

# ── Discrimination notes ────────────────────────────────────────────────────
# Buggy state (commit f7a3defb…) has:
#   - ASSOCIATED_TOKEN_NAMESPACE_KEYS = &["authority", "mint"]   (no idempotent)
#   - 0 occurrences of: BOOLEAN_FLAG_KEYS_BY_NAMESPACE, is_boolean_flag_key,
#     "idempotent", AtaField.idempotent, idempotent_val, idempotent: #
# Fix adds these zero-occurring identifiers, making them strong discriminators.

# ── G1 (0.20): "idempotent" added to ASSOCIATED_TOKEN_NAMESPACE_KEYS ────────
# TODO 1a in the instruction. Match the array literal containing all 3 keys.
g1=0
if grep -qE 'ASSOCIATED_TOKEN_NAMESPACE_KEYS[^=]*=[[:space:]]*&\[[^]]*"idempotent"[^]]*\]' "$KEYWORDS_RS"; then
    g1=1
fi
if [ "$g1" = "1" ]; then emit_gate "g1_idempotent_in_namespace_keys" "pass"; else emit_gate "g1_idempotent_in_namespace_keys" "fail"; fi

# ── G2 (0.20): boolean-flag mechanism wired in keywords module ──────────────
# TODO 1b/1c. Either the new constant or the helper fn must exist in the
# keywords file. Both are zero-occurring in buggy.
g2=0
if grep -qE 'BOOLEAN_FLAG_KEYS_BY_NAMESPACE' "$KEYWORDS_RS" || \
   grep -qE 'fn[[:space:]]+is_boolean_flag_key' "$KEYWORDS_RS"; then
    g2=1
fi
if [ "$g2" = "1" ]; then emit_gate "g2_boolean_flag_mechanism" "pass"; else emit_gate "g2_boolean_flag_mechanism" "fail"; fi

# ── G3 (0.20): AtaField struct gains idempotent: bool field ─────────────────
# TODO 3a. Match `idempotent: bool` (the type annotation form used in struct
# field declarations) anywhere in light_account.rs. Buggy file has 0 of these.
g3=0
if grep -qE '\bidempotent[[:space:]]*:[[:space:]]*bool\b' "$ACCOUNT_RS"; then
    g3=1
fi
if [ "$g3" = "1" ]; then emit_gate "g3_ata_field_idempotent_type" "pass"; else emit_gate "g3_ata_field_idempotent_type" "fail"; fi

# ── G4 (0.15): build_ata_field actually parses the idempotent key ───────────
# TODO 3b/3c. Look for either the local var initialization OR a match arm
# matching "idempotent" string literal inside the file. Both 0-occurring.
g4=0
if grep -qE 'let[[:space:]]+mut[[:space:]]+idempotent' "$ACCOUNT_RS" || \
   grep -qE '"idempotent"[[:space:]]*=>' "$ACCOUNT_RS"; then
    g4=1
fi
if [ "$g4" = "1" ]; then emit_gate "g4_build_ata_field_parses_flag" "pass"; else emit_gate "g4_build_ata_field_parses_flag" "fail"; fi

# ── G5 (0.15): the parsed flag value is stored on AtaField (constructor) ────
# TODO 3d. Canonical patch's final step: include `idempotent` in the
# `Ok(AtaField { ... })` constructor so the parsed value flows into the
# struct. Match either the bare-field-shorthand form (`idempotent,` /
# `idempotent\n` inside a struct literal context) or the explicit form
# (`idempotent: idempotent`). Originally targeted builder.rs codegen
# (`field.idempotent`) but that file's structure has shifted upstream and
# the canonical session may inline codegen elsewhere — accept either path.
g5=0
MACROS_SRC="$REPO/sdk-libs/macros/src"
if [ -d "$MACROS_SRC" ]; then
    # Codegen wiring (preferred — full TODO 4 implementation)
    if grep -rqE 'idempotent_val' "$MACROS_SRC" || \
       grep -rqE 'field\.idempotent' "$MACROS_SRC" || \
       grep -rqE 'idempotent:[[:space:]]*#' "$MACROS_SRC"; then
        g5=1
    # Fallback: AtaField constructor includes idempotent (TODO 3d)
    # `Ok(AtaField { ..., idempotent, })` — match the shorthand-field line
    # `idempotent,` appearing somewhere with a struct constructor nearby.
    # We approximate via Python multi-line check.
    elif python3 -c "
import sys, re, os
src = '$MACROS_SRC'
hit = False
for root, _, files in os.walk(src):
    for f in files:
        if not f.endswith('.rs'): continue
        with open(os.path.join(root, f)) as fp:
            text = fp.read()
        if re.search(r'AtaField\s*\{[^}]*\bidempotent\b', text, re.DOTALL):
            hit = True; break
        if re.search(r'\bidempotent\s*:\s*idempotent\b', text):
            hit = True; break
    if hit: break
sys.exit(0 if hit else 1)
" 2>/dev/null; then
        g5=1
    fi
fi
if [ "$g5" = "1" ]; then emit_gate "g5_field_value_stored" "pass"; else emit_gate "g5_field_value_stored" "fail"; fi

# ── G6 (0.10): ≥1 of the 5 existing call sites updated to carry the flag ────
# TODO 5. The 5 sites (anchor-semi-manual-test, single-ata-test, etc.) all
# need `associated_token::idempotent` appended to keep current behavior.
# Search across sdk-tests/ for the new flag literal.
g6=0
SDK_TESTS="$REPO/sdk-tests"
if [ -d "$SDK_TESTS" ]; then
    if grep -rqE 'associated_token::idempotent' "$SDK_TESTS"; then
        g6=1
    fi
fi
if [ "$g6" = "1" ]; then emit_gate "g6_existing_sites_carry_flag" "pass"; else emit_gate "g6_existing_sites_carry_flag" "fail"; fi

# ── Compute reward (weighted-replace, never additive) ───────────────────────
GATES_FILE="$GATES_FILE" REWARD_FILE="$REWARD_FILE" python3 - <<'PYEOF'
import json, os

gates_path = os.environ["GATES_FILE"]
reward_path = os.environ["REWARD_FILE"]

verdicts = {}
with open(gates_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        verdicts[d["id"]] = d["verdict"]

weights = {
    "g1_idempotent_in_namespace_keys":  0.20,
    "g2_boolean_flag_mechanism":        0.20,
    "g3_ata_field_idempotent_type":     0.20,
    "g4_build_ata_field_parses_flag":   0.15,
    "g5_field_value_stored":            0.15,
    "g6_existing_sites_carry_flag":     0.10,
}
# Σ = 1.00 → inner_weight = 0, reward = sum of passed gate weights

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
with open(reward_path, "w") as f:
    f.write(f"{reward:.4f}\n")
print(f"[eval] reward={reward:.4f}  gates_passed={sum(1 for g in weights if verdicts.get(g)=='pass')}/{len(weights)}")
PYEOF

cat "$REWARD_FILE"
