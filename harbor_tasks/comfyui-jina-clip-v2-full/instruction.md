Implement support for the Jina CLIP v2 text encoder in ComfyUI's main repository.

The implementation should be added as a new file at `comfy/text_encoders/jina_clip_2.py`.

Jina CLIP v2 (available on HuggingFace as `jinaai/jina-clip-v2`) uses a text encoder based on the XLM-RoBERTa architecture. You need to implement this text encoder following ComfyUI's patterns for text encoder integration.

Study the existing text encoder implementations in `comfy/text_encoders/` (e.g., `ace.py`, `flux.py`, `sd3_clip.py`) to understand how ComfyUI structures its text encoder modules. Your implementation should follow the same class hierarchy and integration patterns -- including tokenizer classes, clip model classes, and wrapper classes that ComfyUI expects.

You will need to research the Jina CLIP v2 model to understand its specific architecture, tokenizer configuration, and any differences from standard XLM-RoBERTa (such as positional encoding approach and output pooling strategy).
