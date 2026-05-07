FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential python3 python3-pip python3-venv tmux \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -sL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone the repo at the base commit (before transcript consolidation)
RUN git clone https://github.com/entireio/cli.git /workspace/cli \
    && cd /workspace/cli \
    && git checkout 380a945

# Pre-fetch dependencies
RUN cd /workspace/cli && go mod download

# Setup workspace directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/cli

# Configure git
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"
