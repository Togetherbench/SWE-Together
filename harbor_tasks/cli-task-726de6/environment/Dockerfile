FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux asciinema python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.26.0 (required by go.mod)
RUN curl -sL https://dl.google.com/go/go1.26.0.linux-amd64.tar.gz | tar -C /usr/local -xzf -
ENV PATH="/usr/local/go/bin:$PATH"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone the repo at the base commit (pre-fix state)
RUN git clone https://github.com/entireio/cli.git /repo && \
    cd /repo && \
    git checkout 7f1cdc8c441effc233552e9780c51821939a00db

# Download Go module dependencies
RUN mkdir -p /go && chmod -R 777 /go && cd /repo && go mod download || true

RUN mkdir -p /workspace /logs/verifier /go
# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go /repo

USER agent
WORKDIR /repo

# Set up git config for agent user
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent"
