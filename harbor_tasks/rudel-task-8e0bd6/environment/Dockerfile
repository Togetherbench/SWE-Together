FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip \
    python3 python3-pip python3-venv build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Bun
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash && \
    bun --version

# Clone the repo at the base commit (pre-feature state)
WORKDIR /workspace
RUN git clone https://github.com/obsessiondb/rudel.git && \
    cd rudel && \
    git checkout aa38a30fec325453291cc6ffeb1baa93045f7755 && \
    bun install

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs
USER agent
WORKDIR /workspace/rudel
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
