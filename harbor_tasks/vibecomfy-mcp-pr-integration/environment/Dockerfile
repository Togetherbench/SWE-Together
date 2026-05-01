FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

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
    && rm -rf /var/lib/apt/lists/*

# asciinema is not in Ubuntu 24.04 apt repos by default; install via pip
RUN pip3 install --no-cache-dir --break-system-packages asciinema==2.4.0

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
    numpy==2.2.3 \
    pytest==8.3.5 \
    pytest-timeout==2.3.1

# Set up workspace and log directories
RUN mkdir -p /logs/verifier /logs/agent/sessions

ENV PYTHONPATH=/workspace/VibeComfy

# Create non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/home/agent/.local/bin:$PATH"

# Git config for non-root user
RUN git config --global user.email "agent@harbor.test" && \
    git config --global user.name "Harbor Agent"

WORKDIR /workspace/VibeComfy
