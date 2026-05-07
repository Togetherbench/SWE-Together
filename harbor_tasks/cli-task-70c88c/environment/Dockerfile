FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.9 (go.mod requires >= 1.25.6)
RUN curl -fsSL https://go.dev/dl/go1.25.9.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && echo "00859d7bd6defe8bf84d9db9e57b9a4467b2887c18cd93ae7460e713db774bc1  /tmp/go.tar.gz" | sha256sum -c \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone the repo at the base commit (pre-patch state)
RUN git clone https://github.com/entireio/cli /workspace/cli \
    && cd /workspace/cli \
    && git checkout b386f5faaec2fd2f78941bf3621d89d4000bdf9d

RUN useradd -m -s /bin/bash agent && mkdir -p /logs/verifier

WORKDIR /workspace/cli

# Download Go module dependencies
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Harbor agent install directory
RUN mkdir -p /installed-agent && chown -R agent:agent /installed-agent /workspace /logs /go

USER agent
