FROM python:3.12-slim

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    tmux \
    && rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir asciinema

# Clone the unsloth repo at commit 8f0b57ae (2026-02-02)
# "Use standard gradient checkpointing for small sequence lengths (#3867)"
# This is the last commit before the session on 2026-02-03.
RUN git init /workspace/unsloth && \
    cd /workspace/unsloth && \
    git remote add origin https://github.com/unslothai/unsloth.git && \
    git fetch --depth=1 origin 8f0b57ae18b153c8ef0eff26cc1ac0906af3a73f && \
    git checkout FETCH_HEAD

# Install CPU-only PyTorch (no CUDA needed for structural verification)
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu --index-url https://download.pytorch.org/whl/cpu

# Install core dependencies needed for unsloth to be importable.
# We pin unsloth_zoo to 2026.1.4 -- the version from the session era --
# which contains the buggy requires_grad_pre_hook that crashes on Idefics3.
# Split into separate commands so a failure in one doesn't block the rest.
RUN pip install --no-cache-dir \
    "unsloth_zoo==2026.1.4" \
    "transformers>=4.48.0,<5.0.0" \
    "peft>=0.18.0" \
    "accelerate>=0.34.1" \
    "datasets>=3.4.1,<4.4.0" \
    "trl>=0.15.0,<0.28.0" \
    "sentencepiece>=0.2.0" \
    "protobuf" \
    "packaging" \
    "numpy" \
    "tqdm" \
    "psutil" \
    "tyro" \
    "huggingface_hub>=0.34.0" \
    "hf_transfer" \
    "wheel"

# Install optional deps that may not be available on all architectures
RUN pip install --no-cache-dir "bitsandbytes>=0.45.0" 2>&1 || true
RUN pip install --no-cache-dir "torchvision" 2>&1 || true

# Install unsloth itself in editable mode so agent changes take effect
RUN cd /workspace/unsloth && \
    pip install --no-cache-dir -e . 2>&1 || \
    pip install --no-cache-dir -e ".[huggingfacenotorch]" 2>&1 || true

# Set PYTHONPATH so unsloth modules are importable
ENV PYTHONPATH="/workspace/unsloth:${PYTHONPATH}"

# Commit the initial workspace state so git diff can measure agent changes
RUN cd /workspace/unsloth && \
    git config user.email "harbor@benchmark" && \
    git config user.name "Harbor" && \
    git add -A && \
    git diff --cached --quiet || git commit -m 'initial workspace state'

# Create log directory for verifier output
RUN mkdir -p /logs/verifier

WORKDIR /workspace/unsloth

# Do NOT include test scripts or solutions in the image
