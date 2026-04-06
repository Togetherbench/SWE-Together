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

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/triton
