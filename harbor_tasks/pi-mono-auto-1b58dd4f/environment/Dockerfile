FROM ubuntu:24.04

# Inlined from base_images/pi-mono/Dockerfile (round-5 fix #139): the
# private `ghcr.io/togetherbench/togetherbench/pi-mono-dev:latest` base
# image is at a commit that already contains the session's fix, and we
# can't rebuild it without GHCR push permissions. Inlining the base steps
# here makes the thin-child self-contained — no private-registry dependency
# → builds via E2B `from_dockerfile()` with no auth needed.

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux unzip python3 sudo \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 + Bun 1.3.13 + tsx 4 (matches base_images/pi-mono/Dockerfile).
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g bun@1.3.13 tsx@4

# Non-root agent user (required by claude-code's --dangerously-skip-permissions).
RUN useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /installed-agent && chown agent:agent /installed-agent

RUN mkdir -p /workspace /logs/verifier && \
    chown -R agent:agent /workspace /logs/verifier

WORKDIR /workspace

RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI v2.1.108 (pinned for benchmark reproducibility).
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/root/.local/bin:$PATH"

# Per-task: hard-checkout BASE_COMMIT instead of the silent
# `git fetch ... || true` pattern that left thin-children at
# pi-mono-dev:latest HEAD.
ARG BASE_COMMIT=f86e3c31033c0fe18cb5305c5fa7cf54ab1475d9
RUN set -e && \
    cd /workspace && \
    git clone https://github.com/badlogic/pi-mono.git pi-mono && \
    cd pi-mono && \
    git checkout ${BASE_COMMIT} && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; } && \
    npm ci --ignore-scripts 2>/dev/null || true && \
    chown -R agent:agent /workspace/pi-mono

WORKDIR /workspace/pi-mono
