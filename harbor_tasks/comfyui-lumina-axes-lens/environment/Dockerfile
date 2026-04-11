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

# Create non-root user early so everything is owned by them
RUN useradd -m -s /bin/bash agent

# Create workspace
RUN mkdir -p /workspace /logs/verifier && chown agent:agent /workspace /logs /logs/verifier

WORKDIR /workspace

# Clone ComfyUI (as agent to avoid needing chown later)
USER agent
RUN git init /workspace/ComfyUI && \
    cd /workspace/ComfyUI && \
    git remote add origin https://github.com/comfyanonymous/ComfyUI.git && \
    git fetch --depth=1 origin da2bfb5b0af26c7a1c44ec951dbd0fffe413c793 && \
    git checkout FETCH_HEAD

# Set up Python virtual environment (as agent)
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Install ComfyUI Python dependencies
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

# Install pytest and test dependencies
RUN pip install --no-cache-dir pytest pytest-timeout opencv-python-headless scikit-image

ENV PYTHONPATH="/workspace/ComfyUI"

# Patch model_management.py for CPU-only torch
RUN sed -i 's/if args\.cpu:/if args.cpu or not torch.cuda.is_available():/' \
    /workspace/ComfyUI/comfy/model_management.py

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI as agent user
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:$PATH"

# Remove AGENTS.md / CLAUDE.md that might interfere
RUN rm -f /workspace/ComfyUI/AGENTS.md /workspace/ComfyUI/CLAUDE.md

WORKDIR /workspace/ComfyUI
