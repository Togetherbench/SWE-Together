# Task: sd-scripts-implement-dbf758

| Field | Value |
|-------|-------|
| Source session | `dbf7582b-128f-47b5-bd6a-e6c0cee1236f` |
| Repo | kohya-ss/sd-scripts (12000 stars) |
| Base commit | `a5a162044ca9` |
| Difficulty | medium |
| Category | feature |
| Real user msgs | 9 |

## User Simulator Behavior
- Total real user messages: 9 in 30 turns. Silence is the default.
- Longest silence: ~8 agent turns (during torch.compile implementation)
- Turn-by-turn summary:
  1. **Initial task** — implement fp8_scaled for Lumina (same pattern as HunyuanImage)
  2. **After ~8 turns** — verify FP8_OPTIMIZATION_TARGET_KEYS/EXCLUDE_KEYS exist in Lumina model
  3. **After 1 turn** — consistency check vs musubi-tuner reference implementation
  4. **After ~2 turns** — provide runtime error traceback (NotImplementedError: mul_cuda on fp8)
  5. **After ~2 turns** — ask why use_scaled_mm is not enabled on SM 8.9+
  6. **After 1 turn** — request torch.compile implementation (separate subtask, later reverted)
  7. **After ~8 turns** — report training loss regression (5.0 vs 0.5)
  8. **After ~4 turns** — provide additional debug context (all keys loaded, no missing keys)

## What Must Be Implemented

1. **`library/lumina_util.py`**: Add `FP8_OPTIMIZATION_TARGET_KEYS` (transformer blocks) and `FP8_OPTIMIZATION_EXCLUDE_KEYS` (including `"modulation"` — critical for preventing loss regression), modify `load_lumina_model()` to accept `fp8_scaled` and call `apply_fp8_monkey_patch`.

2. **`library/lumina_train_util.py`**: Add `--fp8_scaled` CLI argument.

3. **`library/fp8_optimization_utils.py`**: Fix `fp8_linear_forward_patch` — the dequantization multiply must cast `scale_weight` to the input tensor dtype (`x.dtype`), not the fp8 dtype of `scale_weight` itself.

## E2E Eval Results

| Metric | Value |
|--------|-------|
| Reward | 0.6 |
| Agent | terminus-2 / claude-opus-4-6 |

## Traces
- [Simulated run](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/sd-scripts-implement-dbf758/trials/sd-scripts-implement-dbf758__HMR2Epe)
