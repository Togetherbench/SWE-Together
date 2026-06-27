# Fix Summary

## Nop Baseline
- Nop reward: 0.10 (target <= 0.10)
- P2P-only weight: 10% (Gate 1: tsc 5%, Gate 2: same-provider ID 5%)

## Session Resolution (Phase 1)
- Tag: resolved
- Confidence: 0.95
- Evidence: User said "Wrap it." (T16), assistant confirmed "Wrapped." with list of changed files, user said "exit" (T17).

## instruction.md Edit
- **Edited**: YES — original instruction referenced local files that don't exist in the Docker environment (`~/Downloads/ec3732e6-...jsonl` and `/var/folders/49/.../pi-clipboard-...png`). These are literally broken references (dead links). Replaced with a self-contained symptom description that preserves the original intent: foreign tool call IDs from github-copilot are improperly normalized for the openai-codex backend.

## User-Sim Prompt Audit (Phase 2)
- Before: 17 rows, all verbatim but with generic trigger conditions ("Intervene IF agent has produced output related to this turn's context")
- After: 16 rows (T2-T17), all verbatim, with observable state-based conditions
- Rebuilt: YES — replaced generic conditions with specific observable conditions (git diff state, file existence, agent output patterns)
- Turn 1 removed from table (it's the instruction.md content, implicit first turn)

## Rubric Compliance (Phase 5)

| Rubric | Tier | Status | Notes |
|--------|------|--------|-------|
| tests_verify_behavior_not_text | A | PASS | bun executes TypeScript calling convertResponsesMessages; tsc compilation gate. 95% weight from execution |
| test_not_tautological | A | PASS | Stub/empty file won't change buggy normalization; F2P gates fail on unmodified code |
| solution_uniqueness_guard | A | PASS | Tests check output != known-buggy value; accepts shortHash, different replacement chars, truncation, any approach |
| no_solution_leakage | A | PASS | instruction.md describes symptom + requirements, not the exact fix (shortHash, signature change, etc.) |
| pass_to_pass_coverage | A | PASS | Gate 1 (tsc) + Gate 2 (same-provider ID) are P2P gates passing on both base and fix |
| behavior_in_task_description | A | PASS | Test strings (Copilot raw IDs, buggy outputs) derivable from instruction.md examples |
| no_hidden_solution_artifacts | A | PASS | No COPY solution/ in Dockerfile; `find / -name 'solve*'` returns nothing |
| dockerfile_determinism | B | PASS | ubuntu:24.04 (exact tag), bun@1.3.13 (pinned), commit hash pinned |
| no_network_during_tests | B | PASS | test.sh only runs bun with local imports, no pip/npm/apt/curl |
| pinned_dependencies | B | PASS | bun@1.3.13 pinned; npm deps via lockfile (npm ci) |
| f2p_p2p_classification_correct | B | PASS | All gates labeled [F2P] or [P2P] in test.sh comments with explanations |

## Agent Discrimination (Phase 4+6)

| Round | Sonnet 4.6 | Haiku 4.5 | Gap  | Notes |
|-------|-----------|-----------|------|-------|
| 1     | 1.00      | 1.00      | 0.00 | Both pass on long IDs; task too easy |
| 2     | 1.00      | 0.75      | 0.25 | Added short foreign ID test (Gate 5) |

### Discrimination Analysis
- Sonnet's fix: Regex-checks if itemId already matches `^fc_[a-zA-Z0-9_-]{1,61}$`; if not, hashes with `fc_${shortHash(itemId)}`. Handles all ID lengths correctly.
- Haiku's fix: Only hashes when `sanitized.length > maxContentLen` (length-based). Short foreign IDs with `/+= chars` still get the buggy character-replacement treatment.
- Gate 5 (short foreign ID) catches this: `foreign/with+special/chars+inside` → Haiku produces `fc_foreign_with_special_chars_inside` (buggy), Sonnet produces `fc_18n5ddks19tsl` (hashed).

## Sim-Fire Validation (Phase 7)
- Status: PASSED
- sim_turns_fired: 9
- Total turns: 10 (6 user turns, 87 agent steps across 10 episodes)
- Agent reward: 1.00
- Fired turns included: T5 (ad-hoc script), T11 (collision probability), T14 (heap snapshots), T15 (mbtree), T16 (wrap it)
- Model: openrouter/minimax/minimax-m2, user-model: openrouter/google/gemini-3.1-pro-preview

## Files Changed
- `tests/test.sh` — created (6 gates: 2 P2P + 4 F2P, partial credit)
- `instruction.md` — rewritten (original referenced non-existent local files)
- `environment/Dockerfile` — pinned bun@1.3.13 (was bun@latest)
- `user_simulation_prompt.md` — rebuilt with observable trigger conditions
- `task.toml` — added session_resolution_reasoning field

## Confidence
- Overall: HIGH
- Remaining concerns:
  - instruction.md was rewritten (original was literally broken for Docker env); change is well-documented
  - Haiku's behavior may vary between runs; the discrimination test targets a genuine code quality difference (length-only vs. universal foreign ID handling)
