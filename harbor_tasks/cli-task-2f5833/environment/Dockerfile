FROM ubuntu:24.04

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    tmux \
    asciinema \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0
RUN curl -fsSL https://go.dev/dl/go1.26.0.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Configure git
RUN git config --global user.email "agent@harbor.test" \
    && git config --global user.name "Harbor Agent" \
    && git config --global init.defaultBranch main

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Clone the repo at the buggy base commit (1d76de91)
# This is the state BEFORE the fix: prompt.txt is overwritten at TurnEnd,
# ExtractSummary is in the agent interface, FirstPrompt is in session state.
RUN git clone https://github.com/entireio/cli.git /workspace/cli \
    && cd /workspace/cli \
    && git checkout 1d76de91

WORKDIR /workspace/cli

# Pre-download Go module dependencies
RUN go mod download 2>/dev/null || true

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/cli
