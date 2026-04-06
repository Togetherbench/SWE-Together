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
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone ComfyUI-WanVideoWrapper at commit b06c7d2 — this is when
# ultravico/sageattn/attn_qk_int8_per_block.py was first introduced
# with the buggy k_scale pointer mutation pattern that causes an
# "operation destroyed but still has uses" LLVM error on AMD GPU (Windows).
# The fix has never been applied to main; agent must fix the Python code.
RUN git init /workspace/ComfyUI-WanVideoWrapper && \
    cd /workspace/ComfyUI-WanVideoWrapper && \
    git remote add origin https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    git fetch --depth=1 origin b06c7d2d6d9bda2cdb6f61e1476f4db37d309f17 && \
    git checkout FETCH_HEAD

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch (agent may want to inspect imports)
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Set PYTHONPATH
ENV PYTHONPATH="/workspace/ComfyUI-WanVideoWrapper"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

WORKDIR /workspace/ComfyUI-WanVideoWrapper
