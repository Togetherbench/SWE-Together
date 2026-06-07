FROM ubuntu:24.04
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    git \
    curl \
    ca-certificates \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Clone the repo at the initial release commit — before any tests were committed
RUN git init /workspace/dataclaw && \
    cd /workspace/dataclaw && \
    git remote add origin https://github.com/banodoco/dataclaw.git && \
    git fetch --depth=1 origin cda7e501452c450a7a8f4cb63b324e32a14247ce && \
    git checkout FETCH_HEAD

# Synthesize the buggy/incomplete state: remove the tests directory
RUN rm -rf /workspace/dataclaw/tests

# Remove any AGENTS.md or CLAUDE.md that might interfere with agent behavior
RUN rm -f /workspace/dataclaw/AGENTS.md /workspace/dataclaw/CLAUDE.md

# Install project dependencies (no GPU needed — pure Python)
RUN cd /workspace/dataclaw && \
    pip install --break-system-packages --no-cache-dir -e ".[dev]"

# Install additional test dependencies
RUN pip install --break-system-packages --no-cache-dir \
    pytest==8.3.4 \
    pytest-cov==6.0.0 \
    pytest-timeout==2.3.1

# Install huggingface_hub (optional dep referenced in the code)
RUN pip install --break-system-packages --no-cache-dir \
    huggingface_hub==0.27.1 || true

# Configure git identity so commits work inside the container
RUN git config --global user.email "harbor@benchmark" && \
    git config --global user.name "Harbor"

# Commit the synthesized state (no tests) as the baseline
RUN cd /workspace/dataclaw && \
    git add -A && \
    git commit --allow-empty -m "initial workspace state"

# Create log directories (verifier + agent sessions used by Harbor runner)
RUN mkdir -p /logs/verifier /logs/agent/sessions

# Set PYTHONPATH so dataclaw is importable
ENV PYTHONPATH="/workspace/dataclaw"

# Create non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs && \
    cp /root/.gitconfig /home/agent/.gitconfig && \
    chown agent:agent /home/agent/.gitconfig

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/home/agent/.local/bin:$PATH"

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/dataclaw && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /workspace/dataclaw
