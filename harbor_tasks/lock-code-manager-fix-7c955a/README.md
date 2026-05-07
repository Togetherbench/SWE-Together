# Task: lock-code-manager-fix-7c955a

| Field | Value |
|-------|-------|
| Source session | `7c955a97-89aa-424d-84c1-3b2571976d8a` |
| Repo | raman325/lock_code_manager (80 stars) |
| Base commit | `de0c2b8034dc0a4f8cb44fe7b1a2dc602c68601e` |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 15 (in 622 total messages, 254 user turns) |

## Summary

Fix a race condition in the Home Assistant Lock Code Manager custom integration where
two config entries sharing the same lock produce "Coordinator missing" warnings and
fail to create entities on startup. Also fix an "Unable to remove unknown job listener"
error on reload caused by trying to unsubscribe an already-removed one-time listener.

Changes span two files:
- `custom_components/lock_code_manager/providers/_base.py` — add `_setup_complete` asyncio.Event gate
- `custom_components/lock_code_manager/__init__.py` — await setup on lock reuse + fix listener unsubscribe

## User Simulator Behavior
- Total real user messages: 15 in 622 turns. Silence is the default.
- Longest silence: 42 agent turns (~85 messages)
- User is hands-off during implementation; intervenes for code review, edge case questions, and architectural feedback. Experienced developer concerned with encapsulation, test quality, and clean API design.

Turn-by-turn summary:
- Turn 0: "Implement the following plan: # Fix overlapping lock coordinator race..." (instruction.md)
- Turn 13: Redirects agent to use Serena for modifications
- Turns 78-91: Reviews `nonlocal` pattern, asks about edge cases, approves
- Turn 176: "push and create PR using PR template"
- Turns 196-250: Code review feedback on encapsulation, test quality, error handling
- Turn 347: "we need to test early returns"
- Turn 422: Reviews architectural changes to provider base class

## Verification Gates

| Gate | Level | Weight | What it checks |
|------|-------|--------|---------------|
| gold_setup_complete_field | GOLD | 0.15 | `_setup_complete` Event field in BaseLock |
| gold_setup_complete_both_paths | GOLD | 0.15 | `.set()` called in early-return AND normal paths |
| gold_lock_reuse_await | GOLD | 0.15 | `await _setup_complete.wait()` on lock reuse |
| gold_safe_unsub_flag | GOLD | 0.15 | `_safe_unsub` uses flag, not try/except |
| silver_all_tests_pass | SILVER | 0.15 | `pytest tests/ -x` exits 0 |
| silver_new_tests_exist | SILVER | 0.05 | New overlapping-locks test functions exist |
| bronze_anti_stub_async_setup | BRONZE | 0.05 | `async_setup` body >3 meaningful statements |
| bronze_on_started_nonlocal | BRONZE | 0.05 | `_on_started` uses `nonlocal` keyword |
| p2p_no_syntax_errors | P2P | 0.0 | Both modified files compile clean |
| p2p_test_suite_runs | P2P | 0.0 | Pytest collects and runs tests |
| p2p_files_exist | P2P | 0.0 | Source files exist on disk |

Total F2P weight: 0.90. Inner weight: 0.10.
