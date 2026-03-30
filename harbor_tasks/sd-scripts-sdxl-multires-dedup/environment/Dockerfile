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

# Clone kohya-ss/sd-scripts at commit 609d1292f6e262b27a8c5b2849e7bf0df2ecd7a8
# "Fix the LoRA dropout issue in the Anima model during LoRA training. (#2272)"
# This is the commit immediately BEFORE "Multi-resolution dataset for SD1/SDXL (#2269)"
# was merged into sd3. The agent must implement multi-resolution caching for SDXL
# and the skip_duplicate_bucketed_images feature.
RUN git clone --branch sd3 https://github.com/kohya-ss/sd-scripts.git /workspace/sd-scripts && \
    cd /workspace/sd-scripts && \
    git checkout 609d1292f6e262b27a8c5b2849e7bf0df2ecd7a8

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch (no GPU needed for structural/behavioral verification)
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu \
    torchvision==0.21.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Install sd-scripts dependencies (pinned to match requirements.txt at base commit)
RUN pip install --no-cache-dir \
    accelerate==1.6.0 \
    transformers==4.54.1 \
    "diffusers[torch]==0.32.1" \
    safetensors==0.4.5 \
    toml==0.10.2 \
    voluptuous==0.15.2 \
    numpy \
    Pillow \
    tqdm \
    huggingface-hub==0.34.3 \
    pyyaml \
    opencv-python-headless \
    einops==0.7.0 \
    ftfy==6.3.1 \
    imagesize==1.4.1 \
    sentencepiece==0.2.1 \
    rich==14.1.0

# Install sd-scripts as editable package (for kohya_ss library imports)
RUN cd /workspace/sd-scripts && pip install --no-cache-dir --no-deps -e .

# Install test dependencies for pass-to-pass verification
RUN pip install --no-cache-dir pytest pytest-timeout

# Set PYTHONPATH so library modules are importable
ENV PYTHONPATH="/workspace/sd-scripts:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

WORKDIR /workspace/sd-scripts
