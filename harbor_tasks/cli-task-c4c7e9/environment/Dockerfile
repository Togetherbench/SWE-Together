FROM ubuntu:24.04

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go
ARG GO_VERSION=1.26.2
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone repo at main HEAD (commit with trail infrastructure but WITHOUT trail title generation)
ARG REPO_COMMIT=47a2e9108ef12085250dce717559a5abd6bc7368
RUN git clone https://github.com/entireio/cli.git /workspace/repo \
    && cd /workspace/repo \
    && git checkout ${REPO_COMMIT}

# Reconstruct the buggy state: add trail title generation code
COPY reconstruct_buggy.py /tmp/reconstruct_buggy.py
RUN python3 /tmp/reconstruct_buggy.py /workspace/repo \
    && rm /tmp/reconstruct_buggy.py

# Download Go module dependencies (offline prep, speeds up agent work)
WORKDIR /workspace/repo
RUN go mod download 2>&1 || true

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier /go
# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent
WORKDIR /workspace/repo

# Set up git config for agent user
RUN git config --global user.email "agent@example.com" \
    && git config --global user.name "Test Agent"
