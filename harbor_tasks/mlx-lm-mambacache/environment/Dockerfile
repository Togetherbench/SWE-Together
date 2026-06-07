FROM python:3.12.8-slim
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

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
# mlx is macOS-only; install will fail on Linux, which is expected.
RUN pip install --no-cache-dir mlx==0.22.2 2>/dev/null || true

# Install regex package (used by tool_parsers: function_gemma, minimax_m2, qwen3_coder)
RUN pip install --no-cache-dir regex==2024.11.6 2>/dev/null || true

# Set PYTHONPATH so mlx_lm is importable
ENV PYTHONPATH="/workspace/mlx-lm:$PYTHONPATH"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    git config --global --add safe.directory /workspace/mlx-lm

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/root/.local/bin:$PATH"

# Remove any AGENTS.md / CLAUDE.md that could interfere with agent behavior
RUN rm -f /workspace/mlx-lm/AGENTS.md /workspace/mlx-lm/CLAUDE.md

# Create non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent && \
    mkdir -p /home/agent/.local/share/claude/versions /home/agent/.local/bin && \
    CLAUDE_VER=2.1.108 && \
    cp /root/.local/share/claude/versions/$CLAUDE_VER /home/agent/.local/share/claude/versions/$CLAUDE_VER && \
    chmod +x /home/agent/.local/share/claude/versions/$CLAUDE_VER && \
    ln -sf /home/agent/.local/share/claude/versions/$CLAUDE_VER /home/agent/.local/bin/claude && \
    chown -R agent:agent /home/agent && \
    chmod -R 777 /workspace /logs && \
    su - agent -c "git config --global user.email agent@test.com && git config --global user.name Agent && git config --global --add safe.directory /workspace/mlx-lm"

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/mlx-lm && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /workspace/mlx-lm
