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
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone sd-scripts at commit e21a773 (Support Anima model — the commit just before
# the user's local multi-resolution SD1/SDXL commit that starts this session).
RUN git init /workspace/sd-scripts && \
    cd /workspace/sd-scripts && \
    git remote add origin https://github.com/kohya-ss/sd-scripts.git && \
    git fetch --depth=1 origin e21a7736f8fdd2477836edf254105518beb9790e && \
    git checkout FETCH_HEAD

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch and torchvision
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu torchvision==0.21.0+cpu --index-url https://download.pytorch.org/whl/cpu

# Install sd-scripts dependencies (pinned to versions from requirements.txt)
RUN pip install --no-cache-dir \
    "accelerate==1.6.0" \
    "transformers==4.54.1" \
    "diffusers[torch]==0.32.1" \
    "ftfy==6.3.1" \
    "opencv-python-headless==4.10.0.84" \
    "einops==0.7.0" \
    "safetensors==0.4.5" \
    "toml==0.10.2" \
    "voluptuous==0.15.2" \
    "huggingface-hub==0.34.3" \
    "imagesize==1.4.1" \
    "lion-pytorch==0.2.3" \
    "schedulefree==1.4" \
    "pytorch-optimizer==3.9.0" \
    "prodigyopt==1.1.2" \
    "rich==14.1.0" \
    "sentencepiece==0.2.1" \
    "Pillow" \
    "tqdm" \
    "numpy" \
    "pytest" \
    "pytest-timeout"

# bitsandbytes may not fully work on CPU but is importable
RUN pip install --no-cache-dir bitsandbytes || true

# Synthesize the "last commit" state: enable multi-resolution for SD1/SDXL in strategy_sd.py.
# This adds multi_resolution=True calls and a load_latents_from_disk override —
# exactly the changes from the user's local commit (HEAD~ in the session).
# NOTE: Using base64-encoded script (E2B's dockerfile_parse doesn't support heredocs).
RUN echo 'cGF0aCA9ICIvd29ya3NwYWNlL3NkLXNjcmlwdHMvbGlicmFyeS9zdHJhdGVneV9zZC5weSIKd2l0aCBvcGVuKHBhdGgsICJyIikgYXMgZjoKICAgIHNyYyA9IGYucmVhZCgpCgojIDEuIEFkZCAiaW1wb3J0IG51bXB5IGFzIG5wIiBiZWZvcmUgdG9yY2ggaW1wb3J0CnNyYyA9IHNyYy5yZXBsYWNlKAogICAgImltcG9ydCB0b3JjaApmcm9tIHRyYW5zZm9ybWVycyBpbXBvcnQgQ0xJUFRva2VuaXplciIsCiAgICAiaW1wb3J0IG51bXB5IGFzIG5wCmltcG9ydCB0b3JjaApmcm9tIHRyYW5zZm9ybWVycyBpbXBvcnQgQ0xJUFRva2VuaXplciIsCikKCiMgMi4gQ2hhbmdlIGlzX2Rpc2tfY2FjaGVkX2xhdGVudHNfZXhwZWN0ZWQgdG8gcGFzcyBtdWx0aV9yZXNvbHV0aW9uPVRydWUKc3JjID0gc3JjLnJlcGxhY2UoCiAgICAiICAgICAgICByZXR1cm4gc2VsZi5fZGVmYXVsdF9pc19kaXNrX2NhY2hlZF9sYXRlbnRzX2V4cGVjdGVkKDgsIGJ1Y2tldF9yZXNvLCBucHpfcGF0aCwgZmxpcF9hdWcsIGFscGhhX21hc2spIiwKICAgICIgICAgICAgIHJldHVybiBzZWxmLl9kZWZhdWx0X2lzX2Rpc2tfY2FjaGVkX2xhdGVudHNfZXhwZWN0ZWQoOCwgYnVja2V0X3Jlc28sIG5wel9wYXRoLCBmbGlwX2F1ZywgYWxwaGFfbWFzaywgbXVsdGlfcmVzb2x1dGlvbj1UcnVlKSIsCikKCiMgMy4gQWRkIGxvYWRfbGF0ZW50c19mcm9tX2Rpc2sgbWV0aG9kIGJlZm9yZSBjYWNoZV9iYXRjaF9sYXRlbnRzCmxvYWRfbWV0aG9kID0gIiIiCiAgICBkZWYgbG9hZF9sYXRlbnRzX2Zyb21fZGlzaygKICAgICAgICBzZWxmLCBucHpfcGF0aDogc3RyLCBidWNrZXRfcmVzbzogVHVwbGVbaW50LCBpbnRdCiAgICApIC0+IFR1cGxlW09wdGlvbmFsW25wLm5kYXJyYXldLCBPcHRpb25hbFtMaXN0W2ludF1dLCBPcHRpb25hbFtMaXN0W2ludF1dLCBPcHRpb25hbFtucC5uZGFycmF5XSwgT3B0aW9uYWxbbnAubmRhcnJheV1dOgogICAgICAgIHJldHVybiBzZWxmLl9kZWZhdWx0X2xvYWRfbGF0ZW50c19mcm9tX2Rpc2soOCwgbnB6X3BhdGgsIGJ1Y2tldF9yZXNvKQoKIiIiCnNyYyA9IHNyYy5yZXBsYWNlKAogICAgIiAgICAjIFRPRE8gcmVtb3ZlIGNpcmN1bGFyIGRlcGVuZGVuY3kgZm9yIEltYWdlSW5mbwogICAgZGVmIGNhY2hlX2JhdGNoX2xhdGVudHMoIiwKICAgIGxvYWRfbWV0aG9kICsgIiAgICAjIFRPRE8gcmVtb3ZlIGNpcmN1bGFyIGRlcGVuZGVuY3kgZm9yIEltYWdlSW5mbwogICAgZGVmIGNhY2hlX2JhdGNoX2xhdGVudHMoIiwKKQoKIyA0LiBDaGFuZ2UgX2RlZmF1bHRfY2FjaGVfYmF0Y2hfbGF0ZW50cyBjYWxsIHRvIHBhc3MgbXVsdGlfcmVzb2x1dGlvbj1UcnVlCnNyYyA9IHNyYy5yZXBsYWNlKAogICAgIiAgICAgICAgc2VsZi5fZGVmYXVsdF9jYWNoZV9iYXRjaF9sYXRlbnRzKGVuY29kZV9ieV92YWUsIHZhZV9kZXZpY2UsIHZhZV9kdHlwZSwgaW1hZ2VfaW5mb3MsIGZsaXBfYXVnLCBhbHBoYV9tYXNrLCByYW5kb21fY3JvcCkiLAogICAgIiAgICAgICAgc2VsZi5fZGVmYXVsdF9jYWNoZV9iYXRjaF9sYXRlbnRzKGVuY29kZV9ieV92YWUsIHZhZV9kZXZpY2UsIHZhZV9kdHlwZSwgaW1hZ2VfaW5mb3MsIGZsaXBfYXVnLCBhbHBoYV9tYXNrLCByYW5kb21fY3JvcCwgbXVsdGlfcmVzb2x1dGlvbj1UcnVlKSIsCikKCndpdGggb3BlbihwYXRoLCAidyIpIGFzIGY6CiAgICBmLndyaXRlKHNyYykKCnByaW50KCJTeW50aGVzaXMgY29tcGxldGU6IHN0cmF0ZWd5X3NkLnB5IHVwZGF0ZWQgd2l0aCBtdWx0aS1yZXNvbHV0aW9uIHN1cHBvcnQiKQo=' | base64 -d > /tmp/synthesize_sd.py && python3 /tmp/synthesize_sd.py && rm /tmp/synthesize_sd.py

# Verify syntax
RUN python3 -c "import ast; ast.parse(open('/workspace/sd-scripts/library/strategy_sd.py').read()); print('strategy_sd.py: syntax OK')"

# Set PYTHONPATH
ENV PYTHONPATH="/workspace/sd-scripts"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Commit synthesis as "the last commit" so agents can see it via git diff HEAD~
# (without this, the shallow clone has only one commit and git diff HEAD~ fails)
# Use --allow-empty in case synthesis replacements didn't match (prevents build failure)
RUN cd /workspace/sd-scripts && \
    git add -A && \
    git diff --cached --quiet && echo "WARNING: synthesis produced no changes" || true && \
    git commit --allow-empty -m "Enable multi-resolution dataset for SD1/SDXL"

# Remove any AGENTS.md / CLAUDE.md that might override agent behavior
RUN rm -f /workspace/sd-scripts/AGENTS.md /workspace/sd-scripts/CLAUDE.md

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash || true
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /workspace/sd-scripts
