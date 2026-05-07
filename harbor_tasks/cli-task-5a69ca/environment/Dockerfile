FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates build-essential \
    python3 python3-pip python3-venv tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Create agent user
RUN useradd -m -s /bin/bash agent

RUN mkdir -p /workspace /logs/verifier /installed-agent

# Clone the repo at the base commit (pre-fix, BUGGY state)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git && \
    cd cli && \
    git checkout 4f09f97c2a2d90f5fa28609ff98dbd9ccb988794

WORKDIR /workspace/cli

# Pre-download Go module dependencies
RUN go mod download

# Give agent ownership of workspace and dependencies
RUN chown -R agent:agent /workspace /logs /installed-agent /go

# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent

# Configure git for agent user
RUN git config --global user.email "agent@example.com" && \
    git config --global user.name "Agent"
