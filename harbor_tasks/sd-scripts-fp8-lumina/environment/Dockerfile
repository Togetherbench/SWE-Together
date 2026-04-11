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

# Clone sd-scripts at commit a5a162044ca9 (2025-10-15).
# This is AFTER fp8_scaled was added for HunyuanImage but BEFORE it was added for Lumina.
# The agent must implement fp8_scaled support for the Lumina model,
# matching the pattern used in library/hunyuan_image_models.py.
RUN git init /workspace/sd-scripts && \
    cd /workspace/sd-scripts && \
    git remote add origin https://github.com/kohya-ss/sd-scripts.git && \
    git fetch --depth=1 origin a5a162044ca953faabdb07742b4b8925f26096ce && \
    git checkout FETCH_HEAD

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch (no GPU needed for structural and behavioral verification)
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu \
    torchvision==0.21.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Install sd-scripts Python dependencies (subset sufficient for CPU verification)
RUN pip install --no-cache-dir \
    transformers==4.47.0 \
    safetensors==0.4.5 \
    accelerate==1.2.1 \
    einops==0.7.0 \
    numpy \
    toml==0.10.2 \
    huggingface-hub==0.26.5 \
    "diffusers[torch]==0.32.1" \
    tokenizers \
    pytest \
    pytest-timeout

# Set PYTHONPATH so sd-scripts modules are importable
ENV PYTHONPATH="/workspace/sd-scripts:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/sd-scripts
