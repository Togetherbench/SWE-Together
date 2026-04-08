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

# Clone ComfyUI at commit da2bfb5b (Dec 12 2025) — "Basic implementation of z image fun control union 2.0"
# This is the state where comfy/ldm/lumina/model.py stores self.axes_lens in NextDiT but
# passes only axes_dims (NOT axes_lens) to EmbedND, effectively ignoring axes_lens in RoPE.
# The agent must implement axes_lens support by creating a LuminaEmbedND class or equivalent.
RUN git init /workspace/ComfyUI && \
    cd /workspace/ComfyUI && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    git fetch --depth=1 origin da2bfb5b0af26c7a1c44ec951dbd0fffe413c793 && \
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
    torchvision \
    einops \
    transformers>=4.28.1 \
    safetensors>=0.4.2 \
    aiohttp \
    pyyaml \
    Pillow \
    scipy \
    tqdm \
    psutil \
    tokenizers>=0.13.3 \
    sentencepiece \
    spandrel

# Install pytest for upstream P2P regression tests
RUN pip install --no-cache-dir pytest pytest-timeout

# Set PYTHONPATH so comfy modules are importable
ENV PYTHONPATH="/workspace/ComfyUI:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/ComfyUI
