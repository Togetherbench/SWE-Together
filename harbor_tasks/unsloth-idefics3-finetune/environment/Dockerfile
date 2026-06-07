FROM python:3.12.13-slim
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    tmux \
    && rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir asciinema==2.4.0

# Clone the unsloth repo at commit 8f0b57ae (2026-02-02)
# "Use standard gradient checkpointing for small sequence lengths (#3867)"
# This is the last commit before the session on 2026-02-03.
RUN git init /workspace/unsloth && \
    cd /workspace/unsloth && \
    git remote add origin https://github.com/unslothai/unsloth.git && \
    git fetch --depth=1 origin 8f0b57ae18b153c8ef0eff26cc1ac0906af3a73f && \
    git checkout FETCH_HEAD

# Install CPU-only PyTorch (no CUDA needed for structural verification)
RUN pip install --no-cache-dir --retries 5 --timeout 300 \
    torch==2.5.1+cpu --index-url https://download.pytorch.org/whl/cpu

# Install core dependencies needed for unsloth to be importable.
# We pin unsloth_zoo to 2026.1.4 -- the version from the session era --
# which contains the buggy requires_grad_pre_hook that crashes on Idefics3.
# Split into separate commands so a failure in one doesn't block the rest.
RUN pip install --no-cache-dir \
    "unsloth_zoo==2026.1.4" \
    "transformers==4.57.6" \
    "peft==0.19.1" \
    "accelerate==1.13.0" \
    "datasets==4.3.0" \
    "trl==0.24.0" \
    "sentencepiece==0.2.1" \
    "protobuf==7.34.1" \
    "packaging==26.1" \
    "numpy==2.4.4" \
    "tqdm==4.67.3" \
    "psutil==7.2.2" \
    "tyro==1.0.13" \
    "huggingface_hub==0.36.2" \
    "hf_transfer==0.1.9" \
    "wheel"

# CPU compat: patch unsloth_zoo's get_device_type to return "cpu" instead of
# raising NotImplementedError on CPU-only Docker.  The function checks for CUDA,
# ROCm, XPU etc. and raises if none found.  We make it fall back to "cpu".
# Patch ALL NotImplementedError raises (there are two: "You need a GPU" and
# "Unsloth currently only works on NVIDIA, AMD and Intel GPUs").
RUN SITE=$(python3 -c "import site; print(site.getsitepackages()[0])") && \
    DT="$SITE/unsloth_zoo/device_type.py" && \
    if [ -f "$DT" ]; then \
      sed -i 's/raise NotImplementedError.*/return "cpu"/' "$DT" && \
      echo "Patched unsloth_zoo device_type.py for CPU compat"; \
    fi

# Set UNSLOTH_IS_PRESENT so unsloth_zoo submodule imports don't fail.
# Normally set by `import unsloth`, but we need it available at all times.
ENV UNSLOTH_IS_PRESENT=1

# Patch unsloth_zoo/temporary_patches for CPU-only environments:
# 1. gpt_oss.py: module-level CUDA memory call crashes on CPU
# 2. utils.py: re-raises ImportError from triton version mismatch
RUN SITE=$(python3 -c "import site; print(site.getsitepackages()[0])") && \
    GPT="$SITE/unsloth_zoo/temporary_patches/gpt_oss.py" && \
    if [ -f "$GPT" ]; then \
      sed -i 's/device_memory = torch\.cuda\.memory\.mem_get_info(0)\[-1\]/device_memory = 0  # patched for CPU/' "$GPT" && \
      sed -i 's/device_memory = torch\.xpu\.memory\.mem_get_info(0)\[-1\]/device_memory = 0  # patched for CPU/' "$GPT" && \
      echo "Patched gpt_oss.py for CPU compat"; \
    fi && \
    UTILS="$SITE/unsloth_zoo/temporary_patches/utils.py" && \
    if [ -f "$UTILS" ]; then \
      sed -i 's/    elif "Unpack" not in e:/    elif "Unpack" not in e and False:/' "$UTILS" && \
      echo "Patched utils.py to not re-raise triton errors"; \
    fi

# Install optional deps that may not be available on all architectures
RUN pip install --no-cache-dir "bitsandbytes==0.49.2" 2>&1 || true
RUN pip install --no-cache-dir --retries 5 --timeout 300 "torchvision==0.20.1+cpu" --index-url https://download.pytorch.org/whl/cpu 2>&1 || true

# Install unsloth itself in editable mode so agent changes take effect
RUN cd /workspace/unsloth && \
    pip install --no-cache-dir -e . 2>&1 || \
    pip install --no-cache-dir -e ".[huggingfacenotorch]" 2>&1 || true

# Set PYTHONPATH so unsloth modules are importable
ENV PYTHONPATH="/workspace/unsloth"

# Remove AGENTS.md / CLAUDE.md if present — these can block or confuse agents
RUN cd /workspace/unsloth && rm -f AGENTS.md CLAUDE.md

# Commit the initial workspace state so git diff can measure agent changes
RUN cd /workspace/unsloth && \
    git config user.email "harbor@benchmark" && \
    git config user.name "Harbor" && \
    git add -A && \
    git diff --cached --quiet || git commit -m 'initial workspace state'

# Create log directory for verifier output
RUN mkdir -p /logs/verifier

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/root/.local/bin:$PATH"

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/unsloth && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===

# === BEGIN DNS sinkhole (PR #221) ===
COPY seal-dns.sh /usr/local/bin/seal-dns.sh
RUN chmod +x /usr/local/bin/seal-dns.sh && \
    if id agent >/dev/null 2>&1; then \
        (command -v sudo >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq --no-install-recommends sudo > /dev/null)) && \
        (grep -q "^agent ALL=" /etc/sudoers 2>/dev/null || echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers); \
    fi
ENV BASH_ENV=/usr/local/bin/seal-dns.sh
ENV ENV=/usr/local/bin/seal-dns.sh
# === END DNS sinkhole ===
WORKDIR /workspace/unsloth

# Do NOT include test scripts or solutions in the image
