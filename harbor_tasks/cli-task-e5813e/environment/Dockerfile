FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.6 (matched to go.mod and mise.toml)
RUN curl -fsSL https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/home/agent/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Create agent user
RUN useradd -m -s /bin/bash agent

# Clone the repo at the parent commit (pre-refactoring state)
RUN git clone https://github.com/entireio/cli /home/agent/cli \
    && cd /home/agent/cli \
    && git checkout d29456f69f13f713027ac55e65832a23ed0610fd

# Set up mise (task runner used by the project) through the go install path
# We don't need mise itself - we use go test directly for verification,
# but the mise.toml config exists in the repo for reference

# Pre-download Go dependencies
WORKDIR /home/agent/cli
RUN go mod download 2>&1 || true

# Verify the project builds at the base commit
RUN go build ./...

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier \
    && chown -R agent:agent /home/agent /workspace /logs

# Allow Harbor to install claude-code at runtime
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent

# Configure git
RUN git config --global user.email "agent@example.com" \
    && git config --global user.name "Harbor Agent"

USER agent

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /home/agent/cli && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /home/agent/cli
