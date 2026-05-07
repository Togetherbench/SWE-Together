FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux asciinema python3 \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0
RUN curl -fsSL https://go.dev/dl/go1.26.0.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:$PATH" \
    GOPATH="/go" \
    GOMODCACHE="/go/pkg/mod"
ENV PATH="$GOPATH/bin:$PATH"

# Working directories
RUN mkdir -p /workspace /logs/verifier

# Clone the repo at the base commit (pre-fix state)
RUN git clone https://github.com/entireio/cli.git /workspace/cli \
    && cd /workspace/cli \
    && git checkout 69b9d730045ad92c202f987e4fee88a3fa0e32aa

# Pre-download Go module dependencies (cached layer)
RUN cd /workspace/cli && go mod download 2>/dev/null || true

WORKDIR /workspace/cli

# Harbor runtime support
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go
USER agent
WORKDIR /workspace/cli
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
