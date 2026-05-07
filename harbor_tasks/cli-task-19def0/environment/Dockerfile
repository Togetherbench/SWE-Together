FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    tmux \
    asciinema \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -sL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

RUN mkdir -p /workspace /logs/verifier

# Clone the repo at the buggy parent commit (pre-fix state)
RUN git clone https://github.com/entireio/cli.git /workspace/repo && \
    cd /workspace/repo && \
    git checkout 7f6c5bd3ce5d041269a2619c66f352607a06d6b2

# Warm the Go module cache
RUN cd /workspace/repo && go mod download 2>/dev/null || true

WORKDIR /workspace/repo

RUN useradd -m -s /bin/bash agent
RUN mkdir -p /installed-agent && chown -R agent:agent /installed-agent /workspace /logs
USER agent
