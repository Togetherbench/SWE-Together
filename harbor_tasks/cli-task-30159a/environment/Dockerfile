FROM ubuntu:24.04

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    tmux \
    asciinema \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0
RUN curl -fsSL -o /tmp/go.tar.gz https://go.dev/dl/go1.26.0.linux-amd64.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Set up working directories
RUN mkdir -p /workspace /logs/verifier

# Clone the repo at the base commit (pre-patch state)
RUN git clone https://github.com/entireio/cli.git /workspace/cli \
    && cd /workspace/cli \
    && git checkout 1278f43b5de25e177d089f9a1dc0b67592c2fc16

# Download Go module dependencies
RUN cd /workspace/cli && go mod download

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/cli

# Set up git config for agent user
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
