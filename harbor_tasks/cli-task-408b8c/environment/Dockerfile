FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux asciinema python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -sL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

RUN mkdir -p /workspace /logs/verifier /go

# Clone the repository at the base commit
RUN git clone https://github.com/entireio/cli.git /workspace/entireio-cli \
    && cd /workspace/entireio-cli \
    && git checkout 02c2e987

WORKDIR /workspace/entireio-cli

# Pre-download Go module dependencies
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent
WORKDIR /workspace/entireio-cli
