FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema unzip sqlite3 jq \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 (provides npm for pnpm install below)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install bun system-wide so it's available after USER agent switch
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Install pnpm (for new-ui)
RUN npm install -g pnpm

# Clone the repo at the base commit (cc8c7f5)
WORKDIR /workspace
RUN git clone https://github.com/desplega-ai/agent-swarm.git && \
    cd agent-swarm && \
    git checkout cc8c7f5

# Install project dependencies
WORKDIR /workspace/agent-swarm
RUN bun install

# Install new-ui dependencies
WORKDIR /workspace/agent-swarm/new-ui
RUN pnpm install 2>/dev/null || true

# Set up environment
ENV PYTHONPATH="/workspace/agent-swarm"

# Create required directories
RUN mkdir -p /logs/verifier

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

# Set up git config for agent user (lands in /home/agent/.gitconfig)
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"
