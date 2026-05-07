FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun system-wide
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Clone repo at the base commit (before the bugfix was applied)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /workspace/gemini-voyager \
    && cd /workspace/gemini-voyager \
    && git checkout 91b04ac

# Install project dependencies
WORKDIR /workspace/gemini-voyager
RUN bun install

ENV PYTHONPATH=/workspace/gemini-voyager

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs
USER agent
WORKDIR /workspace/gemini-voyager
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
