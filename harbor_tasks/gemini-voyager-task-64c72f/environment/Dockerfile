FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip xz-utils \
    python3 python3-pip python3-venv build-essential \
    tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Bun system-wide (required by this TypeScript project)
ENV BUN_INSTALL="/usr/local"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone the repo at the buggy commit (v0.2.8, before the dot-reuse fix)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /app \
    && cd /app \
    && git checkout b44f33836f1d53cdb3e6dab5cc2c92d84ab9f13a

WORKDIR /app

# Install project dependencies
RUN bun i

# Pre-run typecheck to verify baseline compiles
RUN bun run typecheck

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /app

USER agent
WORKDIR /app

# Configure git for the agent (after USER agent so it lands in agent's home)
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"
