FROM ubuntu:24.04

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux asciinema python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0
RUN curl -fsSL https://go.dev/dl/go1.26.0.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}" \
    GOPATH="/go" \
    GOBIN="/go/bin"
RUN mkdir -p "$GOPATH/bin" && chmod -R 777 "$GOPATH"

# Clone the repo at the base commit (the BUGGY state before the fix)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git repo && \
    cd repo && \
    git checkout 988ed897ce0f5474125ffa1ba7442489be7c75c2

# Create log directories for Harbor
RUN mkdir -p /workspace /logs/verifier

ENV PYTHONUNBUFFERED=1

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/repo

# Configure git for agent user
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent" \
    && git config --global init.defaultBranch main
