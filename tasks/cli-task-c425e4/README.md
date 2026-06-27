# Task: cli-task-c425e4

| Field | Value |
|-------|-------|
| Source session | `c425e4bc-c074-44d6-ad17-a1cc912af0ed` |
| Repo | entireio/cli (2213 stars) |
| Base commit | `e9c47e4f8536b5e2c618b2ead9d8784fcc6d361e` |
| Difficulty | easy |
| Category | bugfix |
| Tags | cli, shell, awk, linting, mise |
| Real user msgs | 3 |

## What changed

The `mise-tasks/lint/mise` script checks `mise.toml` for inline multi-line shell scripts that should be extracted to `mise-tasks/` files. Its awk patterns originally anchored at column 1 (`^run = """`), so indented blocks (common in TOML with nested sections) were silently missed.

The canonical fix:
1. Allows leading whitespace (`[ \t]*`) before `run = """` / `run = '''` start delimiters
2. Allows leading whitespace before closing `"""` / `'''` delimiters  
3. Moves the `lines++` increment AFTER the closing delimiter check, so the delimiter line itself is not counted in the reported line count

## Canonical patch

```
mise-tasks/lint/mise: +5/-3 lines
- /^run = """/  →  /^[ \t]*run = """/
- /^"""/        →  /^[ \t]*"""/
- lines++ before closing check  →  check first, then lines++
```

## User Simulator Behavior
- Total real user messages: 3 in 3 turns. Silence is the default.
- Longest silence: ~10 hours (user returned after workday)
- Turn 1: Asked to create the lint script + wire into _default (not in instruction.md)
- Turn 2 (instruction.md): Identified the awk pattern bug with column-1 anchoring
- Turn 3: User typed /exit after agent applied the fix — silent acceptance

## Test Gates (3 P2P_REGRESSION + 5 F2P, Σweights=0.70, inner=0.30)
- P2P: file exists, agent modified it, valid shell syntax
- G1 (0.20): Detects indented `"""` blocks (>3 lines)
- G2 (0.15): No false positives on short blocks (≤3 lines)
- G3 (0.15): Handles `'''` single-quote triple syntax
- G4 (0.10): Regression: still detects non-indented blocks
- G5 (0.10): Closing delimiter not counted in reported line count
