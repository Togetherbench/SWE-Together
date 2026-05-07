FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26
ARG GO_VERSION=1.26.0
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

RUN mkdir -p /workspace /logs/verifier

# Clone the repo at the base commit (pre-canonical-patch state)
RUN git clone https://github.com/entireio/cli.git /workspace/cli \
    && cd /workspace/cli \
    && git checkout a009258cdce04b0dde8c4d559361e8b034ad3ae8

WORKDIR /workspace/cli

# Pre-download Go module dependencies
RUN go mod download

# Configure git system-wide so it applies to any user
RUN git config --system user.email "test@example.com" && \
    git config --system user.name "Test User" && \
    git config --system init.defaultBranch main

ENV PYTHONPATH="/workspace/cli"

# Create agent user and set permissions (Go project — chown /go too)
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/cli
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
