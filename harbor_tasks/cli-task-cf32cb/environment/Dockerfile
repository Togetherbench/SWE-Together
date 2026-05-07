FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema wget \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0 (required by go.mod)
RUN wget -q https://go.dev/dl/go1.26.0.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go1.26.0.linux-amd64.tar.gz && \
    rm go1.26.0.linux-amd64.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier

# Clone repo at the buggy base commit (pre-agent-work state)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git && \
    cd cli && \
    git checkout 78bd0e3d

WORKDIR /workspace/cli

# Download Go module dependencies
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Create agent user and set permissions (Go project — chown /go too)
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/cli

# Configure git for the agent (run after USER so it lands in the agent's HOME)
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
