FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0
RUN wget -q https://go.dev/dl/go1.26.0.linux-amd64.tar.gz -O /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier /go

# Clone repo at the base commit (BUGGY state before the fix)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git repo \
    && cd repo \
    && git checkout d10022cb102738a4c88bf17cca68a0f85401a51c

WORKDIR /workspace/repo

# Download Go module dependencies
RUN go mod download

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/repo

# Set up git config for agent user
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"
