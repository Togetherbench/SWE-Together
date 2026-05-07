FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema unzip sqlite3 jq \
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
WORKDIR /workspace/agent-swarm

# Set up git config for agent user (lands in /home/agent/.gitconfig)
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"
