# Fix Summary

## Nop Baseline
- Nop reward: 0.05 (P2P weight: 5%)
- All F2P tests fail on base: YES (11/11 F2P tests fail, only 5 P2P tests pass)

## Agent Results (Round 1 — prior session)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| GLM 5.1 | 0.05 | 0 (nop) | Answered question only; did not modify code |
| GLM 4.7 | 0.05 | 0 (nop) | Answered question only; did not modify code |

Both models interpreted the original instruction as an exploratory question and didn't modify code. The instruction was subsequently updated (prior session) to be actionable.

## Agent Results (Round 2 — session 2026-04-10)
| Model | Reward | Files Changed | Key Approach |
|-------|--------|---------------|-------------|
| GLM 5.1 | N/A | N/A | **Persistent rate limit** (weekly/monthly exhausted, resets 2026-04-15 13:30:05 UTC) |
| GLM 4.7 | N/A | N/A | **Persistent rate limit** (same API quota) |

Both GLM models returned HTTP 429: `"Weekly/Monthly Limit Exhausted"`. This is a hard weekly quota, not a transient rate limit. Confirmed via sequential Claude Code runs (GLM 5.1 returned error code 1310 after 211s, GLM 4.7 after 284s). Both share the same API key quota.

Error: `{"error":{"code":"1310","message":"Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-04-15 13:30:05"}}`

## Test Refinements

### Pre-existing fixes (applied before this session):
1. **Mock state_dict() populated** (CRITICAL): Returns realistic keys via `z_image_to_diffusers()` so both diffusers-loop and sdk-loop approaches produce `base_model.model.*` keys.
2. **Mutable default argument fixed** (MODERATE): Each call passes explicit `key_map={}` to avoid shared dict bug between n_layers calls.
3. **opencv-python-headless installed** (MINOR): Prevents cv2 import failure in upstream tests.
4. **P2P weights reduced** from 20% to 5%: Better nop/fix discrimination.
5. **instruction.md made actionable**: Changed from exploratory question to direct coding request with explicit guidance ("similar to how it's done for SD3 and PixArt").

### New fix applied (this session):
6. **Test 5 threshold tightened from 80% to 90%** (weight 0.13 → 0.15): The instruction explicitly says to implement "similar to how it's done for SD3 and PixArt." The SD3/PixArt pattern (diffusers-loop) produces base_model.model.* keys that match 1:1 with transformer.* keys (100% ratio). The alternative HunyuanDiT pattern (sdk-loop) produces keys using native naming that only partially overlap with transformer.* keys (87% ratio). The tighter threshold rewards instruction-aligned implementations. Test 14 weight reduced from 0.10 to 0.08 to maintain sum = 1.0.

### Test scoring (16 tests, total 1.00):
| Test | Weight | Type | Description |
|------|--------|------|-------------|
| 1 | 0.01 | P2P | lora.py valid Python |
| 2 | 0.04 | F2P | AST: base_model.model. in Lumina2 block |
| 3 | 0.04 | F2P | AST: key_map assignment with base_model.model |
| 4 | 0.08 | F2P | base_model.model.* keys exist (n_layers=2) |
| 5 | **0.15** | F2P | Key count ratio **>= 90%** of transformer.* |
| 6 | 0.08 | F2P | Layer 0 keys present |
| 7 | 0.08 | F2P | Layer 1 keys present |
| 8 | 0.12 | F2P | >=50% target match with transformer.* |
| 9 | 0.11 | F2P | >=90% target match (strict) |
| 10 | 0.01 | P2P | transformer.* keys still present |
| 11 | 0.01 | P2P | diffusion_model.* keys still present |
| 12 | 0.01 | P2P | lycoris_* keys still present |
| 13 | 0.09 | F2P | n_layers=4 produces more keys than n_layers=2 |
| 14 | **0.08** | F2P | Keys span >=3 distinct component types |
| 15 | 0.08 | F2P | diffusion_model.* target consistency |
| 16 | 0.01 | P2P | Upstream ComfyUI unit tests pass (CPU-safe) |

## Manual Verification Results (re-verified 2026-04-10)

Since agents could not be run due to API rate limits, I manually applied known implementation patterns inside the Docker container and verified scoring with the current test.sh:

| Implementation | Reward | Tests Passed | Key Details |
|---------------|--------|-------------|-------------|
| Nop (no change) | 0.05 | 5/16 | Only P2P tests pass |
| Gold patch (SD3/PixArt diffusers-loop) | **1.00** | **16/16** | 63 base_model.model.* keys, 100% match ratio, 63/63 target match |
| GLM/sdk patch (HunyuanDiT state-dict-loop) | **0.85** | **15/16** | 55 keys, 87% ratio — fails Test 5 (needs ≥90%) |
| Buggy patch (uses `k` instead of `to` as value) | **0.69** | **13/16** | 63 keys but 0/63 target match — fails Tests 8, 9, 15 |

**Discrimination gap between two valid approaches: 0.15** (1.0 vs 0.85)

## Discrimination Analysis
- Score gap (projected): **0.15** if models choose different approaches; **0.00** if both choose the same
- Is this meaningful? **YES, conditionally** — the gap reflects whether agents follow the specific instruction guidance ("similar to SD3 and PixArt"). Models that follow instructions more precisely get higher scores.
- Confidence: **MEDIUM** — Cannot verify with live agents due to rate limits. Prior audit data suggests both GLM models may choose the same approach.

### Discrimination scenarios:
1. **Both use gold pattern** → 1.0 vs 1.0 = gap 0.0 (no discrimination)
2. **One gold, one sdk** → 1.0 vs 0.85 = gap 0.15 (meaningful discrimination)
3. **Both use sdk** → 0.85 vs 0.85 = gap 0.0 (no discrimination)
4. **One succeeds, one fails** → 1.0/0.85 vs 0.05 = gap 0.80+ (clear discrimination)
5. **One makes a bug** → 1.0 vs 0.69 = gap 0.31 (clear discrimination)

### Why stochastic discrimination may emerge:
The instruction's "similar to SD3 and PixArt" hint is moderately directive. A more capable model (5.1) may be more likely to follow this guidance and use the diffusers-loop pattern, while a less capable model (4.7) might default to the simpler sdk-loop pattern. This would produce scenario 2 above.

## Task Health
- Solvable without user sim: **YES** (with the updated actionable instruction)
- Recommended difficulty: **EASY-MEDIUM** (well-specified instruction, single file edit, clear codebase patterns)
- Remaining concerns:
  1. **Rate limit**: GLM API weekly quota exhausted until 2026-04-15 13:30:05 UTC. Must re-run after reset. Both glm-5.1 and glm-4.7 share the same quota.
  2. **Stochastic discrimination**: Whether the 0.15 gap materializes depends on model choices, which are non-deterministic.
  3. **Both-same-approach risk**: If both models consistently choose the same pattern (as seen in the prior audit with the old instruction), discrimination requires one model to make a bug.
  4. **Disk space constraint**: The Docker image is ~10.5GB. Running two containers simultaneously can exhaust the 21GB root partition. Run agents sequentially.
