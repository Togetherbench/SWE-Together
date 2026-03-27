# Task: comfyui-implement-6cb0b2

| Field | Value |
|-------|-------|
| Source session | `6cb0b2c4-dfff-4abc-867b-9387ef8242bf` |
| Repo | comfyanonymous/ComfyUI (55000 stars) |
| Base commit | `31e961736a476851e2579d5d9202ed4177a71720` |
| Difficulty | hard |
| Category | feature |
| Real user msgs | 5 |

## Task Summary

Implement the Jina CLIP v2 text encoder in `comfy/text_encoders/jina_clip_2.py` following ComfyUI idioms. The implementation requires a from-scratch XLM-RoBERTa architecture with rotary positional embeddings (RoPE), mean pooling, and integration with ComfyUI's `SDClipModel`/`SD1ClipModel` class hierarchy.

## User Simulator Behavior

- Total real user messages: 5 in 18 turns. Silence is the default.
- Longest silence: 7 agent turns (user waited while agent investigated)
- Turn-by-turn summary:
  - **Turn 1** (start): Investigation question about existing custom node implementation
  - **Turn 2** (after 7 agent turns): Asked about upstream HuggingFace model architecture
  - **Turn 3** (after 3 agent turns): Asked to find a concrete reference implementation file
  - **Turn 4** (after 3 agent turns): First implementation request — "implement it in this repo" (with modeling_clip.py reference content)
  - **Turn 5** (after 2 agent turns): Correction — "in the ComfyUI main repo, not a custom node" (with all text_encoders reference files)

## Ground Truth

PR [#11415](https://github.com/comfyanonymous/ComfyUI/pull/11415), commit `4c432c11ed6f83466b8ff02569872925753a3c44`.

Key files:
- `comfy/text_encoders/jina_clip_2.py` — XLM-RoBERTa with RoPE, mean pooling, ComfyUI SDClipModel integration
- `comfy/text_encoders/newbie.py` — NewBie dual CLIP using jina_clip_2 (bonus)

## Test Coverage

| Test | Type | Points | Description |
|------|------|--------|-------------|
| 1 | Structural | 0.04 | File exists and parses as valid Python |
| 2 | Structural | 0.06 | Required classes defined (tokenizer, model, wrapper) |
| 3 | Behavioral | 0.08 | Tokenizer inherits SDTokenizer with correct Jina special tokens |
| 4 | Behavioral | 0.10 | JinaClip2TextModel extends SDClipModel |
| 5 | Behavioral | 0.10 | Wrapper class instantiable on CPU |
| 6 | Structural | 0.07 | Non-stub: real architecture (≥4 classes, ≥80 code lines) |
| 7 | Behavioral | 0.08 | Mean pooling over attention mask implemented |
| 8 | Behavioral | 0.08 | Rotary positional embeddings (RoPE) implemented |
| 9 | Behavioral | 0.10 | End-to-end encode_token_weights returns correct tensor shape |
| 10 | Behavioral | 0.10 | Output embedding dimension is 1024 |
| 11 | Behavioral | 0.10 | Multi-layer transformer: ≥20 encoder layers |
| 12 | Behavioral | 0.09 | Mean pooling correctness: masked tokens excluded from output |

**Structural: 17% / Behavioral: 83%**
**Baseline score (no implementation): 0.0**
**Ground truth score (PR #11415): 1.0**

## E2E Eval Results

| Metric | Value |
|--------|-------|
| Reward | **0.71** |
| Sim user msgs | 3 |
| Real user msgs | 5 |
| Agent turns | 24 |
| Executor model | claude-sonnet-4-6 |
| User sim model | claude-opus-4-6 |

## Traces
- [Simulated run](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/comfyui-implement-6cb0b2/trials/comfyui-implement-6cb0b2__NUE4HGq)
- [Original session](https://traces.togetherbench.com/jobs/trials/tasks/original-session/original-session/original/original/comfyui-implement-6cb0b2/trials/comfyui-implement-6cb0b2__original)
