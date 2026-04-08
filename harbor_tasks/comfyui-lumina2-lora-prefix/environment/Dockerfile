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
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone ComfyUI at commit 8e889c5 (Dec 8, 2025).
# This commit has the Lumina2 LoRA key mapping block with diffusion_model., transformer.,
# and lycoris_ entries — but is MISSING the base_model.model. prefix mapping.
# The agent must add: key_map["base_model.model.{}".format(key_lora)] = to
# to the Lumina2 block in comfy/lora.py.
RUN git init /workspace/ComfyUI && \
    cd /workspace/ComfyUI && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    git fetch --depth=1 origin 8e889c535d1fc407bf27dbf8359eef9580f2ed60 && \
    git checkout FETCH_HEAD

# Generic commit message to avoid leaking synthesis context
RUN cd /workspace/ComfyUI && \
    git config user.email "agent@test.com" && \
    git config user.name "Test Agent"

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
    sentencepiece \
    spandrel

# Install pytest for upstream P2P regression tests
RUN pip install --no-cache-dir pytest pytest-timeout

# Set PYTHONPATH so comfy modules are importable
ENV PYTHONPATH="/workspace/ComfyUI"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Install tmux 3.4 from Ubuntu 24.04 debs (apt-get GPG keys expired; use curl+dpkg)
# tmux 3.1+ required for -e flag support in new-session (used by Harbor)
RUN curl -fsSL -o /tmp/libevent.deb \
      "http://archive.ubuntu.com/ubuntu/pool/main/libe/libevent/libevent-core-2.1-7t64_2.1.12-stable-9ubuntu2_amd64.deb" && \
    curl -fsSL -o /tmp/libutempter.deb \
      "http://archive.ubuntu.com/ubuntu/pool/main/libu/libutempter/libutempter0_1.2.1-3build1_amd64.deb" && \
    curl -fsSL -o /tmp/tmux.deb \
      "http://archive.ubuntu.com/ubuntu/pool/main/t/tmux/tmux_3.4-1build1_amd64.deb" && \
    dpkg -i /tmp/libevent.deb /tmp/libutempter.deb /tmp/tmux.deb && \
    rm /tmp/libevent.deb /tmp/libutempter.deb /tmp/tmux.deb

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/ComfyUI
