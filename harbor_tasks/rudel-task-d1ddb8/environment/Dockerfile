FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun (globally available for all users)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH=/usr/local/bin:$PATH

# Clone repo at the exact base commit
RUN git clone https://github.com/obsessiondb/rudel.git /workspace/rudel \
    && cd /workspace/rudel \
    && git checkout 64f29e4a

# Install project dependencies
RUN cd /workspace/rudel && bun install --frozen-lockfile

# Set up working directories
RUN mkdir -p /workspace /logs/verifier

ENV PYTHONPATH=/workspace

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent
WORKDIR /workspace/rudel

# Configure git for agent user (lands in /home/agent/.gitconfig)
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"
