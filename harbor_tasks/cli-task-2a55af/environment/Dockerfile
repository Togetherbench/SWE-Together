FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}" \
    GOPATH="/go" \
    GOMODCACHE="/go/pkg/mod"

RUN mkdir -p /go/pkg/mod

# Clone the repo at the parent commit (buggy state before the fix)
# Full clone required — the base commit is ~3000 commits behind HEAD
RUN git clone https://github.com/entireio/cli.git /workspace/repo \
    && cd /workspace/repo \
    && git checkout b51e394d8f87fdd1c96d14869625e5da5a181f71

WORKDIR /workspace/repo

# Download Go module dependencies
RUN go mod download

# Configure git
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"

RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/repo
