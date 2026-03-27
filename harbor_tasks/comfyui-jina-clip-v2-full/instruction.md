Implement the Jina CLIP v2 model architecture in the ComfyUI main repo, not a custom node. You may refer to `comfy/text_encoders/` for how other text encoders are implemented and follow the same idioms. You may fully rewrite the code to follow ComfyUI patterns.

The implementation should go in `comfy/text_encoders/jina_clip_2.py` and include:
- A tokenizer class (following the `SDTokenizer` pattern used by other encoders)
- A tokenizer wrapper class (following the `SD1Tokenizer` wrapper pattern)
- The XLM-RoBERTa model architecture (the backbone used by Jina CLIP v2)
- A text model class extending `SDClipModel`
- A text model wrapper class extending `SD1ClipModel`

Jina CLIP v2 uses a modified XLM-RoBERTa architecture with:
- SentencePiece tokenizer (pad_with_end=False, max_length=8192)
- Rotary position embeddings (RoPE) instead of learned position embeddings
- Mean pooling over the sequence (weighted by attention mask)
- Hidden size: 1024, 24 layers, 16 attention heads

Reference the existing implementations in `comfy/text_encoders/` (e.g., `ace.py`, `flux.py`, `sd3_clip.py`) for the ComfyUI integration patterns.
