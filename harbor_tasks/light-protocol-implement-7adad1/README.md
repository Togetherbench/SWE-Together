# Task: light-protocol-implement-7adad1

| Field | Value |
|-------|-------|
| Source session | `7adad1d7-2fa8-4694-9cf8-1e40b25edd6c` |
| Repo | Lightprotocol/light-protocol (329 stars) |
| Base commit | `f7a3defb5095dfb82cf05cbc16701b6edb1054e3` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 8 |

## Task Summary

Add an `associated_token::idempotent` boolean flag to the `#[light_account]` proc-macro. Currently, ATA creation codegen hardcodes idempotent behavior. The flag allows users to opt into non-idempotent (strict) ATA creation. Changes span the macro keyword system, the `AtaField` struct, the parse paths, and the codegen builder.

## User Simulator Behavior

- **Total real user messages**: 8 in 218 total messages. Silence is the default.
- **Longest silence**: 69 agent turns (~4 min) between Turn 1 and Turn 2
- **Pattern**: User provides a detailed plan upfront, then issues a course correction ("no dont update existing sites"), followed by test verification questions, and a final targeted instruction to add the idempotent flag to one specific existing test site.

### Turn-by-turn summary

| Turn | What user said | Why |
|------|---------------|-----|
| 1 | Detailed plan (~10KB) to implement the idempotent flag | User did the design work, handing off implementation |
| 2 | "no dont update existing sites" | Course correction — skip TODO 5 from the plan |
| 3 | "revert these changes" with specific file lists | Ensure reverts are comprehensive |
| 4 | "do all integration tests pass?" | Checking agent's work after test run |
| 5 | Pasted test error output | Sharing debug context |
| 6 | "is that previous test or did you add it?" | Investidiagnostic test failure origin |
| 7 | "ok what test did you add what asserts does it have?" | Understanding test landscape before deciding fix |
| 8 | "ok then add the idempotent flag to the other one that asserts idempotent behavior" | Targeted fix — add flag to specific test site only |

## Key Files

| File | Role |
|------|------|
| `sdk-libs/macros/src/light_pdas/light_account_keywords.rs` | Keyword definitions, boolean flag system |
| `sdk-libs/macros/src/light_pdas/accounts/light_account.rs` | AtaField struct and parsing |
| `sdk-libs/macros/src/light_pdas/accounts/token.rs` | ATA codegen (currently hardcodes idempotent) |
| `sdk-tests/csdk-anchor-full-derived-test/src/instructions/d10_token_accounts/single_ata.rs` | Existing test site that needs the flag |

## Verification

- 6 F2P gates using tree-sitter AST checks and `cargo test -p light-sdk-macros`
- 1 P2P_REGRESSION gate ensuring AtaField original fields are preserved
- Weighted-replace reward formula, Σ F2P weights = 1.0
