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

RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone sd-scripts at commit 34e7138 — the last commit before the
# min_orig_resolution / rebalance_regularization_images feature was added.
RUN git clone https://github.com/kohya-ss/sd-scripts.git /workspace/sd-scripts && \
    cd /workspace/sd-scripts && \
    git checkout 34e7138b6a80c2d88f40c99fd68879c6e683f639

WORKDIR /workspace/sd-scripts

# Install CPU-only PyTorch and required deps (no GPU needed for structural checks)
RUN pip3 install --break-system-packages --no-cache-dir \
    torch==2.6.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Install remaining dependencies (ignore GPU-specific extras that fail on CPU)
RUN pip3 install --break-system-packages --no-cache-dir \
    accelerate \
    transformers \
    diffusers \
    safetensors \
    toml \
    imagesize \
    Pillow \
    numpy \
    tqdm \
    packaging \
    opencv-python-headless \
    2>/dev/null || true

# Apply synthesis: add the min_orig_resolution feature with DUPLICATE balancing loops
# (the "buggy state" the agent must refactor)
COPY synthesize_buggy_state.py /workspace/synthesize_buggy_state.py
RUN cd /workspace/sd-scripts && python3 /workspace/synthesize_buggy_state.py && \
    rm /workspace/synthesize_buggy_state.py

# Set PYTHONPATH so library modules are importable
ENV PYTHONPATH="/workspace/sd-scripts:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Stage the synthesized changes so agent sees them via git diff HEAD
RUN cd /workspace/sd-scripts && git add -A && \
    git commit -m "initial workspace state"

WORKDIR /workspace/sd-scripts
