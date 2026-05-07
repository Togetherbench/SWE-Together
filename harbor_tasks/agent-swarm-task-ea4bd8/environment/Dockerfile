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
WORKDIR /workspace/agent-swarm

# Configure git for agent user
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"

# Default to bash
CMD ["/bin/bash"]
