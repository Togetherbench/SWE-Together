FROM ubuntu:24.04

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema wget util-linux \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz

# Clone the repo at the pre-fix base commit
RUN git clone https://github.com/entireio/cli.git /opt/entire-cli && \
    cd /opt/entire-cli && \
    git checkout cef002c0b1b4e19421173dabf69b6ba976a0bf1a

WORKDIR /opt/entire-cli

# Set up Go environment
ENV GOPATH=/go
ENV PATH=/usr/local/go/bin:/go/bin:$PATH

# Install Go dependencies
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Set up environment
RUN mkdir -p /workspace /logs/verifier /go

ENV PYTHONPATH=/opt/entire-cli

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go /opt/entire-cli
USER agent
WORKDIR /opt/entire-cli
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
