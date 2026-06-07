FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema unzip jq \
    && rm -rf /var/lib/apt/lists/*

# Install Bun system-wide so it survives the USER agent switch
ENV BUN_INSTALL="/usr/local"
ENV PATH="/usr/local/bin:$PATH"
RUN curl -fsSL https://bun.sh/install | bash

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Clone repo at the base commit (pre-patch state)
WORKDIR /workspace
RUN git clone https://github.com/desplega-ai/agent-swarm.git /workspace/agent-swarm \
    && cd /workspace/agent-swarm \
    && git checkout c3a5e1a4c0eeadd87057629db2baa0d0abe1575e

# Install project dependencies (needed for TypeScript type checking during testing)
WORKDIR /workspace/agent-swarm
RUN bun install --frozen-lockfile || true

# Set up PYTHONPATH for test scripts
ENV PYTHONPATH="/workspace/agent-swarm:${PYTHONPATH}"

# Install PyYAML for test manifest parsing
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install pyyaml
ENV PATH="/opt/venv/bin:$PATH"

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/agent-swarm && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /workspace/agent-swarm

# Configure git for agent user
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"

# Default to bash
CMD ["/bin/bash"]
