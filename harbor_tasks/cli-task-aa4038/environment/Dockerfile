FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

RUN git clone https://github.com/entireio/cli.git && \
    cd cli && \
    git checkout 1b69ae14da4a0d3deb08922bb6798b9bc5fb6e02

WORKDIR /workspace/cli

RUN go mod download

ENV PYTHONPATH=""

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

USER agent

RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"
