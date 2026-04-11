FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    build-essential \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone triton at commit 0bc402c (Feb 5 2026, PR #9366 "[ConSan] First pass at improving ConSan compile times").
# This commit introduces WarpSpecializeUtility.cpp with two size_t->unsigned narrowing bugs:
#   1. lib/Conversion/TritonGPUToLLVM/WarpSpecializeUtility.cpp line ~94:
#      `partition->walk([&, idx = idx]` -- idx is size_t from llvm::enumerate, captured into
#      a lambda that passes it to functions expecting std::optional<unsigned>. MSVC C4267 error.
#   2. Same file, line ~249:
#      `op->getResult(i)` -- i is size_t from llvm::enumerate, getResult() expects unsigned. C4267.
# The agent must add explicit casts (e.g. static_cast<unsigned>) to fix both narrowings.
#
# Uses blobless clone (--filter=blob:none) to avoid downloading the full 1GB+ LLVM submodule history.
RUN git clone --filter=blob:none https://github.com/triton-lang/triton.git /workspace/triton && \
    cd /workspace/triton && \
    git checkout 0bc402c968b069a45ab326526b08232e55eb2cee

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    git config --global commit.gpgsign false

# Add development guidelines
RUN printf '%s\n' \
    "# Development Notes" \
    "" \
    "## Cross-platform build" \
    "This project targets Linux (GCC/Clang) and Windows (MSVC)." \
    "Windows CI uses \`/WX\` (warnings-as-errors) so all narrowing warnings must be fixed." \
    "" \
    "## Fixing warnings" \
    "When fixing a type-conversion or narrowing warning, grep the entire file for" \
    "similar patterns — the same category of bug often occurs at multiple call sites." \
    "The MSVC error log may only surface one instantiation, but the same root cause" \
    "(e.g. size_t used where unsigned is expected) can appear wherever \`llvm::enumerate\`" \
    "index variables are passed to typed APIs." \
    > /workspace/triton/CLAUDE.md

# Create non-root user for Claude Code (--dangerously-skip-permissions requires non-root)
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs

# Pre-install Claude Code CLI as non-root user
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:$PATH"

# Git config for non-root user
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    git config --global commit.gpgsign false

WORKDIR /workspace/triton
