Add full Unsloth fine-tuning support for models using the Idefics3 architecture (like IBM's Granite Docling VLM). This should cover all Unsloth training modes (SFT, DPO, GRPO, etc.) and follow the same patterns used for other VLMs already supported in the codebase.

## What you need to implement

1. **Create a `FastIdefics3Model` class** in a new module under `unsloth/models/` (e.g., `idefics.py`) following the patterns of existing VLM support. The class should:
   - Implement a `from_pretrained` classmethod that delegates to the appropriate HuggingFace model class (e.g., `Idefics3ForConditionalGeneration`)
   - Include proper LoRA/PEFT configuration targeting the right projection layers for Idefics3
   - Have substantive methods for model setup and integration with Unsloth's training pipeline

2. **Register and export the model**:
   - Add `"idefics3"` to `VLLM_SUPPORTED_VLM` in `unsloth/models/vision.py`
   - Export the new class from `unsloth/models/__init__.py`

3. **Fix the hook compatibility issue**: Idefics3 has a composite/nested `get_input_embeddings()` that does not return a simple `torch.nn.Embedding`. This causes `unsloth_zoo.peft_utils.requires_grad_pre_hook` to receive empty tuple inputs and crash with `RuntimeError: Unsloth: Failed to make input require gradients!`. Fix this by either:
   - Monkey-patching the hook to handle empty tuple inputs gracefully (return them as-is instead of crashing), OR
   - Overriding `get_input_embeddings()` in your `FastIdefics3Model` to return the proper text embedding layer directly

## Guidelines
- Study existing VLM implementations in `unsloth/models/` to understand the patterns and conventions
- The `unsloth_zoo` package is installed separately — you can monkey-patch its functions from your module
- Do not break existing model support — preserve all existing exports and VLM entries
