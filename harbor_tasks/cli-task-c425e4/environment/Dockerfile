FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Clone the repo at the base commit (before the fix)
RUN git clone https://github.com/entireio/cli.git /opt/cli \
    && cd /opt/cli \
    && git checkout e9c47e4f8536b5e2c618b2ead9d8784fcc6d361e

WORKDIR /opt/cli

RUN mkdir -p /workspace /logs/verifier

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /opt/cli
USER agent
WORKDIR /opt/cli
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
