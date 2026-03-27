# Task: nunchaku-implement-a56d1e

| Field | Value |
|-------|-------|
| Source session | `a56d1e94-cd8d-4966-bc32-287497f43dd5` |
| Repo | mit-han-lab/nunchaku (600 stars) |
| Base commit | `8f41840596bd516d434a1f88ac16c86fdb64e74f` |
| Difficulty | hard |
| Category | feature |
| Real user msgs | 4 |

## Summary

Agent must implement SVDQ weight dequantization for the Nunchaku quantization
framework used in Qwen-Image-Edit. Given five packed tensors
(`proj_down`, `proj_up`, `qweight`, `wscales`, `smooth_factor`), write
`reconstruct_weight.py` with correct unpack functions that reverse
`NunchakuWeightPacker(bits=4, warp_n=128)` and reconstruct the original BF16
weight matrix.

The core challenge: nunchaku packs weights into a custom tiled memory layout
optimized for GPU MMA operations. The agent must read `nunchaku/lora/flux/packer.py`
to understand the layout and implement the inverses of `pack_weight`,
`pack_scale`, and `pack_lowrank_weight`.

## User Simulator Behavior

- **Total real user messages**: 4 over ~44 agent turns. Silence is the default.
- **Longest silence**: ~14 agent turns
- **Communication pattern**: directive then hands-off; only intervenes to refocus scope, expand test coverage, or redirect after failure

### Turn-by-turn summary

| Turn | After # agent turns | Message |
|------|---------------------|---------|
| 1 | 0 (start) | Full task spec: read nunchaku source, write reconstruct_weight.py for `attn.to_out.0` |
| 2 | ~15 | Scope correction: agent drifted to full quantization pipeline, user redirects to dequant only |
| 3 | ~29 | Expand: "test all 6 parameters" |
| 4 | ~31 | "Just fix the function and pass the tests" (no cleanup needed) |

## Verification

Scoring (0.0–1.0):

| Test | Weight | Type | Description |
|------|--------|------|-------------|
| Bronze: file + functions | 0.10 | Structural | `reconstruct_weight.py` has 4 required functions |
| Silver1: qweight roundtrip | 0.20 | Behavioral | `unpack_svdq_qweight` exactly reverses `pack_weight` |
| Silver2: scale roundtrip | 0.15 | Behavioral | `unpack_svdq_scale` exactly reverses `pack_scale` |
| Silver3: lowrank roundtrip | 0.15 | Behavioral | `unpack_svdq_lowrank` exactly reverses `pack_lowrank_weight` |
| Gold1: full recon (square) | 0.20 | Behavioral | Reconstruction matches expected for square shapes |
| Gold2: full recon (all 6) | 0.20 | Behavioral | Reconstruction matches expected for all 6 layer types |

- Buggy baseline: **0.20** (qweight unpack works, scale/lowrank missing)
- Correct solution: **1.0**

## E2E Eval Results

| Metric | Value |
|--------|-------|
| Reward | 0.25 |
| Agent | terminus-2 / claude-opus-4-6 |

## Traces
- [Simulated run](https://traces.togetherbench.com/jobs/trials/tasks/_/terminus-2/anthropic/claude-opus-4-6/nunchaku-implement-a56d1e/trials/nunchaku-implement-a56d1e__U4McUZo)
