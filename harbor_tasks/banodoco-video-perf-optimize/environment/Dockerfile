FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies + Node.js 20 (via NodeSource)
RUN apt-get update -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    && apt-get install -y --no-install-recommends --allow-unauthenticated \
    git \
    curl \
    ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh \
    && bash /tmp/nodesource_setup.sh \
    && apt-get install -y --allow-unauthenticated nodejs \
    && rm -rf /var/lib/apt/lists/* /tmp/nodesource_setup.sh

# Create workspace and log directories
RUN mkdir -p /workspace /logs/verifier /logs/agent/sessions

WORKDIR /workspace

# Clone xliry/banodoco-wrapped at commit 13a06f8
RUN git init /workspace/banodoco-wrapped && \
    cd /workspace/banodoco-wrapped && \
    git remote add origin https://github.com/xliry/banodoco-wrapped.git && \
    git fetch --depth=1 origin 13a06f8d91c6eece10bf42c4218c4fe6fa83636b && \
    git checkout FETCH_HEAD

# Install npm dependencies (includes typescript, tsx, vite, recharts, framer-motion)
RUN cd /workspace/banodoco-wrapped && npm install

# Remove any AGENTS.md / CLAUDE.md that could interfere with agent behavior
RUN rm -f /workspace/banodoco-wrapped/AGENTS.md /workspace/banodoco-wrapped/CLAUDE.md

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

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
RUN cd /workspace/banodoco-wrapped && \
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
WORKDIR /workspace/banodoco-wrapped
