FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    wget tar \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.5 (matching .mise.toml)
RUN wget -q https://go.dev/dl/go1.25.5.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf go1.25.5.linux-amd64.tar.gz \
    && rm go1.25.5.linux-amd64.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier /installed-agent /go/bin

# Clone repo at the buggy base commit
RUN git clone https://github.com/entireio/cli.git /repo \
    && cd /repo && git checkout 65fa5640

# Python deps for verifier
RUN pip3 install --break-system-packages pyyaml

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /repo /go

USER agent
WORKDIR /repo

# Configure git for agent user
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"
