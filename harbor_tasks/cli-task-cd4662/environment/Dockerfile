FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6 (matches go.mod)
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"

# Clone repo at the base commit (pre-fix, buggy state)
RUN git clone https://github.com/entireio/cli.git /entire-cli \
    && cd /entire-cli \
    && git checkout 4f09f97c2a2d90f5fa28609ff98dbd9ccb988794

# Pre-download Go module dependencies
WORKDIR /entire-cli
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Set up environment
ENV PYTHONPATH="/entire-cli"
RUN mkdir -p /workspace /logs/verifier /go

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /entire-cli /installed-agent /logs /go

USER agent
WORKDIR /entire-cli

# Configure git as the agent user so config lives under /home/agent/.gitconfig
RUN git config --global user.email "agent@test.local" \
    && git config --global user.name "Test Agent" \
    && git config --global init.defaultBranch main
