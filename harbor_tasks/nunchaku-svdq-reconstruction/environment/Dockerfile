FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace /logs/verifier

# Clone nunchaku at pinned commit
RUN git clone https://github.com/mit-han-lab/nunchaku.git /workspace/nunchaku && \
    cd /workspace/nunchaku && \
    git checkout 8f41840596bd516d434a1f88ac16c86fdb64e74f

# Install CPU-only PyTorch + minimal deps (no CUDA required)
RUN pip install --no-cache-dir --break-system-packages \
    torch==2.6.0+cpu --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir --break-system-packages safetensors

# Set PYTHONPATH so nunchaku package is importable
ENV PYTHONPATH=/workspace/nunchaku

WORKDIR /workspace

# Create keys reference files (tensor shape documentation)
RUN printf 'attn.to_out.0.proj_down  [3072, 128]  BF16\nattn.to_out.0.proj_up    [3072, 128]  BF16\nattn.to_out.0.qweight    [3072, 1536] I8\nattn.to_out.0.smooth_factor [3072]   BF16\nattn.to_out.0.wscales    [48, 3072]  BF16\nimg_mlp.net.2.proj_down  [12288, 128] BF16\nimg_mlp.net.2.proj_up    [3072, 128]  BF16\nimg_mlp.net.2.qweight    [3072, 6144] I8\nimg_mlp.net.2.smooth_factor [12288]  BF16\nimg_mlp.net.2.wscales    [192, 3072] BF16\n' > /workspace/keys_svdq_r128.txt

# Synthesize test data and buggy initial reconstruct_weight.py
COPY synthesize_buggy_state.py /tmp/synthesize_buggy_state.py
RUN cd /workspace && python3 /tmp/synthesize_buggy_state.py && rm /tmp/synthesize_buggy_state.py

# Configure git for agent commits
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    cd /workspace && git init && git add -A && \
    git commit -m "initial workspace state"

WORKDIR /workspace
