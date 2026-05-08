FROM ubuntu:24.04

# Prevent interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential wget \
    python3 python3-pip python3-venv tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0
RUN curl -fsSL https://go.dev/dl/go1.26.0.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="/go/bin:${PATH}"

# Configure git
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent" \
    && git config --global init.defaultBranch main

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier /go
# Clone the repo at the base commit (pre-patch state)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git \
    && cd cli \
    && git checkout 5268246a18f069b450de4feff863bd80e7ea759e

# Download Go module dependencies
WORKDIR /workspace/cli
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Pre-install gotestsum for test runner
RUN go install gotest.tools/gotestsum@latest 2>/dev/null || true

# Install golangci-lint for linting
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b /usr/local/bin v2.10.1

# Create agent user for Harbor
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /installed-agent /workspace /logs /go

USER agent
WORKDIR /workspace/cli
