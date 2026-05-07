FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv build-essential tmux asciinema unzip \
    && rm -rf /var/lib/apt/lists/*

# Install bun system-wide (so agent user can access it)
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:$PATH"

# Clone the repo at the base commit (tip of main before the fix)
RUN git clone https://github.com/obsessiondb/rudel.git /workspace/rudel && \
    cd /workspace/rudel && \
    git checkout 5f27d8f

WORKDIR /workspace/rudel

# Install dependencies
RUN bun install

# Create workspace dirs for Harbor
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent
WORKDIR /workspace/rudel

# Configure git for agent user (lands in /home/agent/.gitconfig)
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"
