FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    unzip \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install bun system-wide so the agent user can execute it
ENV BUN_INSTALL="/usr/local"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:$PATH"

# Set PYTHONPATH
ENV PYTHONPATH="/workspace"

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Clone repo at the base commit (parent of canonical patch)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /workspace/repo && \
    cd /workspace/repo && \
    git checkout 8ff844f0e8d94184023077d21e4fd70cbe2db5cc

# Install project dependencies
WORKDIR /workspace/repo
RUN bun install

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent
WORKDIR /workspace/repo

# Set git identity for the agent (after USER agent so it lands in agent's home)
RUN git config --global user.email "agent@harbor.local" \
    && git config --global user.name "Harbor Agent"
