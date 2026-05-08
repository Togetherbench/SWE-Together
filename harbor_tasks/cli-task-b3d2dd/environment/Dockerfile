FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.2 (matches go.mod)
RUN curl -sSL https://go.dev/dl/go1.26.2.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:$PATH"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone the repository at the base commit (before the bug fix)
RUN git clone https://github.com/entireio/cli.git /workspace/cli
WORKDIR /workspace/cli
RUN git checkout 56cdda512ae7242e0801535d92e6aa13e7f71502

# Pre-download Go module dependencies
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Set up directories for Harbor
RUN mkdir -p /workspace /logs/verifier /go
# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent
WORKDIR /workspace/cli

# Configure git for tests (lands in /home/agent/.gitconfig)
RUN git config --global user.email "test@test.com" && git config --global user.name "Test"
