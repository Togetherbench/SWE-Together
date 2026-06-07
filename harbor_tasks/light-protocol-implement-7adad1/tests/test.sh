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
#
# _self_critique_log (sonnet v3 review, 2026-06-06):
#   iteration 1:
#     issue_found: "g1 grep used literal \"idempotent\" only — rejects valid
#       negative-polarity implementations that register \"non_idempotent\".
#       Rubric goal_1 (v3.1) explicitly accepts both polarities."
#     fix_applied: "Widened g1 regex to \"(non_)?idempotent\". g1 weight
#       reduced 0.20 → 0.15 to make room for new g7/g8 gates."
#   iteration 2:
#     issue_found: "g6 grepped sdk-tests/ for `associated_token::idempotent`
#       only. Under negative polarity (`non_idempotent` keyword, idempotent
#       default), Turn-2 honoring leaves existing sites unmodified — rubric
#       goal_6 branch (b) is conformant but the gate had no detection path."
#     fix_applied: "Added two negative-polarity branches: (i) accept
#       `associated_token::non_idempotent` literal in sdk-tests/, (ii) accept
#       when `non_idempotent` is registered in the namespace-keys array
#       (proves negative polarity was chosen). g6 weight 0.10 → 0.08."
#   iteration 3:
#     issue_found: "Rubric goals 7 (new instruction file under
#       d10_token_accounts/) and 8 (new integration test asserting
#       second-call failure) had combined weight 0.20 but zero verifier
#       coverage. Ceiling for a perfect negative-polarity implementation
#       capped at 0.70."
#     fix_applied: "Added g7 (0.08): canonical-named OR equivalent new .rs
#       file under d10_token_accounts/ containing `#[light_account(init,
#       associated_token::` attribute + mod.rs registration + lib.rs
#       visibility (glob re-export or explicit reference). Added g8 (0.07):
#       canonical-named OR equivalent new test file referencing the new
#       instruction with a second-call-fails assertion pattern (is_err /
#       unwrap_err / `Err(` / `should fail` / `already exists`). Anti-stub
#       check rejects `fn it_works() {}` placeholders."
#   weight_check: 0.15 + 0.18 + 0.18 + 0.13 + 0.13 + 0.08 + 0.08 + 0.07 = 1.00
#   polarity_check: g1, g6, g7, g8 all polarity-neutral; g2, g3, g4, g5
#     untouched (already polarity-neutral — they pin behavioral mechanism,
#     not keyword string, and accept any boolean field name).
#   anti_gaming_check: g7 excludes pre-existing files (mod.rs, single_ata.rs,
#     single_ata_markonly.rs) so an agent cannot pass g7 by editing the
#     existing single_ata.rs. g8 rejects `it_works` stub and requires both
#     instruction reference AND failure assertion.
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
#
# POLARITY NEUTRALITY (per v3.1 rubric, sonnet review 2026-06-06):
# The user's behavioral need is a toggleable flag between idempotent and strict
# ATA creation. Either keyword polarity satisfies goals 1 and 6:
#   - Positive polarity: keyword is "idempotent"; default behavior is strict;
#     existing sites add the flag to retain their idempotent semantics.
#   - Negative polarity: keyword is "non_idempotent"; default behavior is
#     idempotent; existing sites are left unmodified by design (Turn 2).
# Gates g1 and g6 below accept BOTH polarities; gates g7/g8 cover the new
# instruction file + integration test (rubric goals 7/8, both polarity-neutral).

# ── G1 (0.15): "idempotent" or "non_idempotent" in ASSOCIATED_TOKEN_NAMESPACE_KEYS
# TODO 1a in the instruction. Match the array literal containing the new keyword
# in EITHER polarity (positive: "idempotent" / negative: "non_idempotent").
g1=0
if grep -qE 'ASSOCIATED_TOKEN_NAMESPACE_KEYS[^=]*=[[:space:]]*&\[[^]]*"(non_)?idempotent"[^]]*\]' "$KEYWORDS_RS"; then
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

# ── G6 (0.08): pre-existing idempotent ATA semantics preserved ──────────────
# Rubric goal_6 is polarity-neutral:
#   (a) Positive polarity: at least one existing site adds
#       `associated_token::idempotent` to keep its idempotent behavior, OR
#   (b) Negative polarity: the new keyword is `non_idempotent` and the
#       implementation's default is idempotent — existing sites correctly stay
#       unmodified (Turn 2 "no dont update existing sites"). We detect this by
#       (i) the negative keyword appearing in sdk-tests/ (as the new
#       non-idempotent variant test would use it), OR
#       (ii) the keywords file registering `non_idempotent` (proving negative
#       polarity was chosen) while leaving the pre-existing idempotent
#       `single_ata.rs` site unchanged.
g6=0
SDK_TESTS="$REPO/sdk-tests"
if [ -d "$SDK_TESTS" ]; then
    # Branch (a): explicit positive-polarity flag added to an existing site.
    if grep -rqE 'associated_token::idempotent\b' "$SDK_TESTS"; then
        g6=1
    # Branch (b): negative polarity demonstrated either in sdk-tests/ usage
    # or via the keywords-file registration. In negative polarity the existing
    # sites are correctly left at their (already-idempotent) default.
    elif grep -rqE 'associated_token::non_idempotent\b' "$SDK_TESTS"; then
        g6=1
    elif grep -qE '"non_idempotent"' "$KEYWORDS_RS"; then
        g6=1
    fi
fi
if [ "$g6" = "1" ]; then emit_gate "g6_existing_sites_carry_flag" "pass"; else emit_gate "g6_existing_sites_carry_flag" "fail"; fi

# ── G7 (0.10): new instruction file under d10_token_accounts/ ───────────────
# Rubric goal_7 (Turn 1 TODOs 6/7/8). Polarity-neutral: the new instruction file
# demonstrates the strict (non-idempotent) variant — under positive polarity it
# omits the `idempotent` flag, under negative polarity it carries the
# `non_idempotent` flag. We credit the goal when:
#   (a) the canonical-named file `single_ata_non_idempotent.rs` exists under
#       d10_token_accounts/, OR
#   (b) any new .rs file under d10_token_accounts/ (i.e., not `mod.rs` and not
#       the pre-existing `single_ata.rs` / `single_ata_markonly.rs`) contains a
#       `#[light_account(init, associated_token::` attribute (the strict
#       variant's defining feature), AND
#   (c) the module is registered in d10_token_accounts/mod.rs AND visible from
#       lib.rs (either via an explicit `D10SingleAtaNonIdempotent` reference or
#       via the existing `instructions::d10_token_accounts::*` glob — checked
#       by mod.rs registration alone since lib.rs glob-imports the module).
g7=0
D10_DIR="$REPO/sdk-tests/csdk-anchor-full-derived-test/src/instructions/d10_token_accounts"
LIB_RS="$REPO/sdk-tests/csdk-anchor-full-derived-test/src/lib.rs"
if [ -d "$D10_DIR" ] && [ -f "$D10_DIR/mod.rs" ]; then
    new_file_present=0
    # Canonical name
    if [ -f "$D10_DIR/single_ata_non_idempotent.rs" ]; then
        new_file_present=1
    else
        # Any new .rs file (not mod.rs/single_ata.rs/single_ata_markonly.rs)
        # containing a #[light_account(init, associated_token:: attribute.
        for f in "$D10_DIR"/*.rs; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            case "$base" in
                mod.rs|single_ata.rs|single_ata_markonly.rs)
                    continue
                    ;;
            esac
            if grep -qE '#\[light_account\(init[^)]*associated_token::' "$f"; then
                new_file_present=1
                break
            fi
        done
    fi
    # Module registration in mod.rs
    mod_registered=0
    if grep -qE '^[[:space:]]*pub[[:space:]]+mod[[:space:]]+single_ata_non_idempotent\b' "$D10_DIR/mod.rs"; then
        mod_registered=1
    else
        # Accept any pub mod line that names a new module file we identified
        for f in "$D10_DIR"/*.rs; do
            [ -f "$f" ] || continue
            base=$(basename "$f" .rs)
            case "$base" in
                mod|single_ata|single_ata_markonly)
                    continue
                    ;;
            esac
            if grep -qE "^[[:space:]]*pub[[:space:]]+mod[[:space:]]+${base}\b" "$D10_DIR/mod.rs"; then
                mod_registered=1
                break
            fi
        done
    fi
    # lib.rs visibility: glob re-export of d10_token_accounts::* is sufficient,
    # or explicit reference to a D10SingleAtaNonIdempotent identifier.
    lib_visible=0
    if [ -f "$LIB_RS" ]; then
        if grep -qE 'instructions::d10_token_accounts::\*' "$LIB_RS" || \
           grep -qE 'D10SingleAtaNonIdempotent' "$LIB_RS" || \
           grep -qE 'd10_single_ata_non_idempotent' "$LIB_RS"; then
            lib_visible=1
        fi
    fi
    if [ "$new_file_present" = "1" ] && [ "$mod_registered" = "1" ] && [ "$lib_visible" = "1" ]; then
        g7=1
    fi
fi
if [ "$g7" = "1" ]; then emit_gate "g7_new_instruction_file" "pass"; else emit_gate "g7_new_instruction_file" "fail"; fi

# ── G8 (0.10): new integration test asserting second-call failure ───────────
# Rubric goal_8 (Turn 1 TODO 9). Polarity-neutral: the test must exercise the
# new non-idempotent instruction and demonstrate strict-creation semantics by
# asserting that a SECOND call fails. We credit:
#   (a) the canonical-named file `d10_ata_idempotent_test.rs` exists in
#       sdk-tests/csdk-anchor-full-derived-test/tests/, OR
#   (b) any new .rs file under that tests/ dir (not pre-existing
#       d10_token_accounts_test.rs) that references the new instruction
#       (`d10_single_ata_non_idempotent` or `D10SingleAtaNonIdempotent`),
# AND in either case the file must contain a second-call-fails assertion
# pattern (`is_err()`, `assert!(.*err`, `unwrap_err`, `Err(`, `should fail`,
# or `already exists`).
g8=0
TESTS_DIR="$REPO/sdk-tests/csdk-anchor-full-derived-test/tests"
if [ -d "$TESTS_DIR" ]; then
    candidate=""
    if [ -f "$TESTS_DIR/d10_ata_idempotent_test.rs" ]; then
        candidate="$TESTS_DIR/d10_ata_idempotent_test.rs"
    else
        for f in "$TESTS_DIR"/*.rs; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            case "$base" in
                d10_token_accounts_test.rs)
                    continue
                    ;;
            esac
            if grep -qE '(d10_single_ata_non_idempotent|D10SingleAtaNonIdempotent)' "$f"; then
                candidate="$f"
                break
            fi
        done
    fi
    if [ -n "$candidate" ]; then
        if grep -qE '(\.is_err\(\)|unwrap_err|assert!\([^)]*err|\bErr\(|should[[:space:]]+fail|already[[:space:]]+exists)' "$candidate"; then
            # Also reject obvious stubs: a single `#[test] fn it_works() {}`
            # or a single-line empty test body.
            if ! grep -qE '^[[:space:]]*fn[[:space:]]+it_works[[:space:]]*\([[:space:]]*\)[[:space:]]*\{[[:space:]]*\}' "$candidate"; then
                g8=1
            fi
        fi
    fi
fi
if [ "$g8" = "1" ]; then emit_gate "g8_new_integration_test_second_call_fails" "pass"; else emit_gate "g8_new_integration_test_second_call_fails" "fail"; fi

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
    "g1_idempotent_in_namespace_keys":           0.15,
    "g2_boolean_flag_mechanism":                 0.18,
    "g3_ata_field_idempotent_type":              0.18,
    "g4_build_ata_field_parses_flag":            0.13,
    "g5_field_value_stored":                     0.13,
    "g6_existing_sites_carry_flag":              0.08,
    "g7_new_instruction_file":                   0.08,
    "g8_new_integration_test_second_call_fails": 0.07,
}
# Σ = 1.00 → inner_weight = 0, reward = sum of passed gate weights
# Rebalanced 2026-06-06 (sonnet v3 review): g1 0.20→0.15 (oracle-bias fix);
# g2 0.20→0.18, g3 0.20→0.18, g4 0.15→0.13, g5 0.15→0.13 (shaved to make
# room for new gates); g6 0.10→0.08 (oracle-bias fix); g7 NEW 0.08
# (rubric goal_7 was uncovered); g8 NEW 0.07 (rubric goal_8 was uncovered).

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
