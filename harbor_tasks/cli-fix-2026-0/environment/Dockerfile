FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.5 (matching go.mod at base commit)
RUN curl -fsSL https://go.dev/dl/go1.25.5.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Clone repo at base commit (before any session changes)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git repo
WORKDIR /workspace/repo
RUN git checkout 7cd5dfae

# Set up Go environment
ENV GOPATH="/workspace/repo/.go"
ENV GOMODCACHE="/workspace/repo/.go/pkg/mod"

# Download dependencies
RUN go mod download

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier

# Set PYTHONPATH
ENV PYTHONPATH="/workspace"

# Configure git
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"

# Create user for Harbor
RUN useradd -m agent && \
    mkdir -p /installed-agent && \
    chown -R agent:agent /workspace /logs /installed-agent

USER agent
WORKDIR /workspace/repo
