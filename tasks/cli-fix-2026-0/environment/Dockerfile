FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.5 (matching go.mod at base commit)
RUN curl -fsSL https://go.dev/dl/go1.25.5.linux-amd64.tar.gz | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Clone repo at base commit (before any session changes)
WORKDIR /workspace
RUN git clone https://github.com/entireio/cli.git repo
WORKDIR /workspace/repo
RUN git checkout 7cd5dfae

# Set up Go environment
ENV GOPATH="/workspace/repo/.go"
ENV GOMODCACHE="/workspace/repo/.go/pkg/mod"

# Download dependencies
RUN go mod download

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier

# Set PYTHONPATH
ENV PYTHONPATH="/workspace"

# Configure git
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"

# Create user for Harbor
RUN useradd -m agent && \
    mkdir -p /installed-agent && \
    chown -R agent:agent /workspace /logs /installed-agent

USER agent

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/repo && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===

# === BEGIN DNS sinkhole (PR #221) ===
USER root
COPY seal-dns.sh /usr/local/bin/seal-dns.sh
RUN chmod +x /usr/local/bin/seal-dns.sh && \
    if id agent >/dev/null 2>&1; then \
        (command -v sudo >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq --no-install-recommends sudo > /dev/null)) && \
        (grep -q "^agent ALL=" /etc/sudoers 2>/dev/null || echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers); \
    fi
ENV BASH_ENV=/usr/local/bin/seal-dns.sh
ENV ENV=/usr/local/bin/seal-dns.sh
USER agent
# === END DNS sinkhole ===
WORKDIR /workspace/repo
