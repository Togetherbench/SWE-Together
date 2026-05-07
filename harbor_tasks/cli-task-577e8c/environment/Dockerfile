FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}" \
    GOPATH="/go" \
    GOBIN="/go/bin"

RUN mkdir -p "$GOPATH" "$GOBIN"

# Clone the repo at the base commit (pre-fix state)
RUN git clone https://github.com/entireio/cli.git /app \
    && cd /app \
    && git checkout 092146da477575eeaf5219df24e225c3777687d3

ENV PYTHONPATH="/app"

RUN mkdir -p /workspace /logs/verifier /tests

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go /app
USER agent
WORKDIR /app
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
