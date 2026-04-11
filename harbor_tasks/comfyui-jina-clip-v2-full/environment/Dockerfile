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

# Clone ComfyUI at base commit 31e9617 — this is the state just BEFORE
# the Jina CLIP v2 implementation was added (PR #11415, merged Dec 20 2025).
# comfy/text_encoders/jina_clip_2.py does not exist at this commit.
# The agent must implement it from scratch following ComfyUI idioms.
RUN git init /workspace/ComfyUI && \
    cd /workspace/ComfyUI && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    git fetch --depth=1 origin 31e961736a476851e2579d5d9202ed4177a71720 && \
    git checkout FETCH_HEAD

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch (no GPU needed for structural verification)
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Install ComfyUI Python dependencies (CPU-sufficient subset)
RUN pip install --no-cache-dir \
    transformers>=4.50.3 \
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

# Install pytest for pass-to-pass upstream test verification
RUN pip install --no-cache-dir pytest pytest-timeout

# Patch model_management.py to default to CPU mode (no CUDA in this environment).
# ComfyUI normally detects GPU at startup; since we use CPU-only PyTorch, we force
# cpu_state = CPUState.CPU so imports work without a GPU present.
RUN sed -i 's/^cpu_state = CPUState\.GPU$/cpu_state = CPUState.CPU/' \
    /workspace/ComfyUI/comfy/model_management.py

# Set PYTHONPATH so comfy modules are importable
ENV PYTHONPATH="/workspace/ComfyUI:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


# Remove any AGENTS.md / CLAUDE.md that could interfere with agent behavior
RUN rm -f /workspace/ComfyUI/AGENTS.md /workspace/ComfyUI/CLAUDE.md

WORKDIR /workspace/ComfyUI
