FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone the repo at the buggy base commit (before the fix)
RUN git clone https://github.com/entireio/cli.git /workspace/repo \
    && cd /workspace/repo \
    && git checkout 380a9451b5d268fcc230bfb217b9df7ba4def8c6

WORKDIR /workspace/repo

# Download Go module dependencies
RUN go mod download

RUN mkdir -p /logs/verifier /workspace /go

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/repo

# Configure git as the agent so config lives under /home/agent
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent" \
    && git config --global init.defaultBranch main
