It seems MLX LM lib doesnt allow us to run the model Qwen3-Next-80B (currently using) with batch and prompt caching. Can you deploy your subagent to verify this? A few resources for you to look over:
- mlx-lm folder in root
- mlx-lm/mlx_lm/examples/batch_generate_response.py
- mlx-lm/mlx_lm/cache_prompt.py
Confirm?
