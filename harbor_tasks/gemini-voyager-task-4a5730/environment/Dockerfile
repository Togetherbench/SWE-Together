FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates unzip xz-utils build-essential \
    python3 python3-pip python3-venv python3-yaml \
    jq tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install bun system-wide so it's accessible to the agent user
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone repo at the buggy state (pre-fix commit 69d734b)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /workspace/repo \
    && cd /workspace/repo \
    && git checkout 69d734b

WORKDIR /workspace/repo

# Install project dependencies
RUN bun install

# Harbor runtime directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs
USER agent
WORKDIR /workspace/repo
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
