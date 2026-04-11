FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Configure git
RUN git config --global user.email "agent@harbor.test" && \
    git config --global user.name "Harbor Agent"

# Clone VibeComfy at the base commit (head of PR #1 before session changes)
RUN git init /workspace/VibeComfy && \
    cd /workspace/VibeComfy && \
    git remote add origin https://github.com/peteromallet/VibeComfy.git && \
    git fetch --depth=1 origin eba7a29aae86be3af23739618bd2504e5bf77af7 && \
    git checkout FETCH_HEAD && \
    git checkout -b workspace

# Remove files that could over-guide agents (CLAUDE.md has full CLI reference)
RUN rm -f /workspace/VibeComfy/CLAUDE.md /workspace/VibeComfy/AGENTS.md

# Install Python dependencies
# mcp: the MCP server framework used by cli_tools/registry/mcp_server.py
# numpy: used by cli_tools/registry/embeddings.py
RUN pip3 install --break-system-packages \
    mcp==1.3.0 \
    numpy \
    pytest \
    pytest-timeout

# Set up workspace
RUN mkdir -p /logs/verifier

ENV PYTHONPATH=/workspace/VibeComfy

# Create non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs

# Pre-install Claude Code CLI as non-root user
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:$PATH"

# Git config for non-root user
RUN git config --global user.email "agent@harbor.test" && \
    git config --global user.name "Harbor Agent"

WORKDIR /workspace/VibeComfy
