FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone ComfyUI at master commit 5ac3b26a7ded (2025-12-14, just before the session).
# This commit has clip_text_dim support in comfy/ldm/lumina/model.py (which the PR removes)
# and does NOT yet have the NewBie architecture files.
# Force master to point to this exact commit so `git diff master newbie` works correctly.
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI && \
    cd /workspace/ComfyUI && \
    git checkout 5ac3b26a7dedb9b13c681abe8733c54f13353273 && \
    git branch -f master HEAD

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch (no GPU needed for structural verification)
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Install ComfyUI's Python dependencies (CPU-sufficient subset)
RUN pip install --no-cache-dir \
    transformers>=4.28.1 \
    safetensors>=0.4.2 \
    aiohttp \
    einops \
    pyyaml \
    Pillow \
    scipy \
    tqdm \
    psutil \
    tokenizers>=0.13.3 \
    sentencepiece

# Set PYTHONPATH so comfy modules are importable
ENV PYTHONPATH="/workspace/ComfyUI:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Apply initial (non-idiomatic) NewBie PR state:
# - Removes clip_text_dim support from comfy/ldm/lumina/model.py
# - Creates comfy/ldm/newbie/ with anti-pattern code (wrong return value,
#   wrong timestep direction, nn.init calls, _pop_unexpected_kwargs, etc.)
# - Adds NewBieImage to model_base.py (with unnecessary apply_model override)
# - Adds NewBieImageModel to supported_models.py
COPY synthesize_buggy_state.py /workspace/synthesize_buggy_state.py
RUN cd /workspace/ComfyUI && python3 /workspace/synthesize_buggy_state.py && \
    rm /workspace/synthesize_buggy_state.py

# Set up branches so `git diff master newbie` works as in the session.
# We're in detached HEAD after checkout + branch -f master. Commit synthesis changes
# in detached HEAD, then create newbie branch pointing to that commit.
# Result: master = clean base commit, newbie = base + anti-pattern NewBie code.
RUN cd /workspace/ComfyUI && \
    git add -A && \
    git commit -m "initial workspace state" && \
    git checkout -b newbie

WORKDIR /workspace/ComfyUI
