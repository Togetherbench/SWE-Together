FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux asciinema \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0 (matching go.mod)
RUN curl -fsSL https://go.dev/dl/go1.26.0.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone the repo at the base commit (pre-patch state)
RUN git clone https://github.com/entireio/cli.git /repo/cli \
    && cd /repo/cli \
    && git checkout febf309b5a54770f084a3028c31df17f54205a0f

WORKDIR /repo/cli

# Install Go dependencies
RUN go mod download

# System-wide git safety config (applies to all users)
RUN git config --system safe.directory '*'

RUN mkdir -p /workspace /logs/verifier

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go /repo
USER agent
WORKDIR /repo/cli
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
