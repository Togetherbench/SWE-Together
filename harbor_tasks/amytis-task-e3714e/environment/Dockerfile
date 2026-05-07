FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun (system-wide, not under /root)
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:$PATH"

# Clone the repo at the base commit (pre-bugfix state)
RUN git clone https://github.com/hutusi/amytis.git /opt/amytis && \
    cd /opt/amytis && \
    git checkout e0a5f415434c1588b9950dd5e55757fe14e7630a

WORKDIR /opt/amytis

# Install project dependencies
RUN bun install

# Harbor directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /opt/amytis

USER agent
WORKDIR /opt/amytis

# Configure git for any in-container operations
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"
