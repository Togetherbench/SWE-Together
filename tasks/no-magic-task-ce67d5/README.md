# Task: no-magic-task-ce67d5

| Field | Value |
|-------|-------|
| Source session | `ce67d562-2214-46e6-80e0-a9b99d4a3215` |
| Repo | Mathews-Tom/no-magic (91 stars) |
| Base commit | `9a876115d119638e2d2dcd09028001ae258563d7` (v3.0.0) |
| Difficulty | medium |
| Category | bugfix |
| Real user msgs | 2 |

## Task Summary

Implement a Byte-Pair Encoding (BPE) tokenizer in `01-foundations/microtokenizer.py` following a detailed specification. The script must download the makemore names dataset, train BPE merge rules, verify round-trip encode/decode correctness, and report compression ratio. Zero external dependencies — stdlib only.

## User Simulator Behavior
- Total real user messages: 2 in 35 turns. Silence is the default.
- Longest silence: 22 agent turns
- Turn 1: Detailed implementation plan for `microtokenizer.py`
- Turn 2 (after agent demonstrates working code): "commit this"

## Verification

The test harness (tests/test.sh) validates:
1. P2P gates: file exists, non-trivial implementation (>=80 lines, >=3 functions with body depth >3)
2. gate_syntax (0.10): Python syntax check passes
3. gate_executes (0.20): Script runs to completion within 120s
4. gate_roundtrip (0.25): All 6 round-trip encode/decode tests pass
5. gate_compression (0.20): Compression ratio >= 1.5x
6. gate_training (0.15): Training progress shows >= 8 merge steps
7. gate_stdlib (0.10): No imports outside Python stdlib

## CI/CD Source
- `.github/workflows/verify.yml` — syntax check, random.seed(42), no external imports, full script execution
- `.github/workflows/catalog.yml` — catalog generation (not relevant to this task)
