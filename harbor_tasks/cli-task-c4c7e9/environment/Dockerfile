FROM ubuntu:24.04

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Go
ARG GO_VERSION=1.26.2
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -o /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Clone repo at the natural pre-fix commit (parent of 8b01d8e0 "Remove trail title generation").
# This commit ships the real buggy state — trail_title.go exists, summarize import +
# generateTrailTitleForTrail are wired into manual_commit_hooks.go — so no synthesis
# step is needed and the canonical patch (reference_patch.json) applies cleanly.
# Previously this Dockerfile checked out 47a2e9108e (post-fix on main, hundreds of
# commits later) and used reconstruct_buggy.py to reinject the deleted code; that
# produced a structurally divergent state where 2 of 3 canonical hunks failed.
ARG REPO_COMMIT=cef3938d6f9a678a364567482033a219dc0d22db
RUN git clone https://github.com/entireio/cli.git /workspace/repo \
    && cd /workspace/repo \
    && git checkout ${REPO_COMMIT}

# Download Go module dependencies (offline prep, speeds up agent work)
WORKDIR /workspace/repo
RUN go mod download 2>&1 || true

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier /go
# Create agent user and set permissions
# NOTE: /go must be chowned to agent so `go mod download` / build cache work at runtime
# (without this, the agent user hits permission denied on GOPATH).
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /go

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

# Set up git config for agent user
RUN git config --global user.email "agent@example.com" \
    && git config --global user.name "Test Agent"
