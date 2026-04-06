FROM ubuntu:24.04

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

# Configure git for agent use (generic message to avoid hinting at synthesis strategy)
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/openclaw
