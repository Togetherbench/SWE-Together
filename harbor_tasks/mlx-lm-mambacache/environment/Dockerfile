FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone mlx-lm at commit 298b67c (last main commit before PR #739).
# At this commit, ArraysCache/MambaCache lack merge/extract/prepare/finalize,
# CacheList lacks merge/extract, and _merge_caches() only handles KVCache/RotatingKVCache.
RUN git init /workspace/mlx-lm && \
    cd /workspace/mlx-lm && \
    git remote add origin https://github.com/ml-explore/mlx-lm.git && \
    git fetch --depth=1 origin 298b67c755f4dc0fd47b0d1baa591607798d384d && \
    git checkout FETCH_HEAD

# Install mlx-lm in editable mode (CPU-only -- no Metal/GPU needed for structural tests)
RUN cd /workspace/mlx-lm && \
    pip install --no-cache-dir -e ".[dev]" 2>/dev/null || \
    pip install --no-cache-dir -e . || true

# Ensure mlx is installed (CPU-only stub is sufficient for unit tests)
RUN pip install --no-cache-dir mlx 2>/dev/null || true

# Install regex package (used by tool_parsers: function_gemma, minimax_m2, qwen3_coder)
RUN pip install --no-cache-dir regex 2>/dev/null || true

# Set PYTHONPATH so mlx_lm is importable
ENV PYTHONPATH="/workspace/mlx-lm:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/mlx-lm
