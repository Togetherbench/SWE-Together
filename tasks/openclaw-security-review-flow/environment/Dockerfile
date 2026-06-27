FROM ubuntu:24.04
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

# Create workspace and log directories
RUN mkdir -p /workspace /logs/verifier

# Install Node.js 22 (has built-in TypeScript strip-types support)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install tsx globally for TypeScript execution in verifier
# tsx uses esbuild to strip types and run TS files without compilation
RUN npm install -g tsx@4 typescript@5

# Clone OpenClaw at the base commit (2026-02-01 18:20 UTC).
# This is BEFORE the prompt-injection security module was added (session started 2026-02-01T18:55).
# The session creates: src/security/risk-tiers.ts, pattern-check.ts, risk-classifier.ts,
# reviewer.ts, decision-flow.ts, index.ts, gateway-integration.ts, audit-log.ts, approval-manager.ts
RUN git init /workspace/openclaw && \
    cd /workspace/openclaw && \
    git remote add origin https://github.com/OpenClaw/OpenClaw.git && \
    git fetch --depth=1 origin 17287bc8d01b12a293e0452a76b1c117dd1e42c1 && \
    git checkout FETCH_HEAD

# Remove repo-level agent config files that can mislead agents
# (e.g. "Prefer Bun" instructions, repo-specific conventions)
RUN rm -f /workspace/openclaw/AGENTS.md /workspace/openclaw/CLAUDE.md

# Install project dependencies (skip native addon builds — only needed for vitest P2P tests)
RUN corepack enable && \
    cd /workspace/openclaw && \
    pnpm install --frozen-lockfile --ignore-scripts 2>&1 | tail -5

# Configure git for agent use (generic message to avoid hinting at synthesis strategy)
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
RUN cd /workspace/openclaw && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /workspace/openclaw
