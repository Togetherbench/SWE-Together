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

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/cli && \
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
COPY seal-dns.sh /usr/local/bin/seal-dns.sh
RUN chmod +x /usr/local/bin/seal-dns.sh && \
    if id agent >/dev/null 2>&1; then \
        (command -v sudo >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq --no-install-recommends sudo > /dev/null)) && \
        (grep -q "^agent ALL=" /etc/sudoers 2>/dev/null || echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers); \
    fi
ENV BASH_ENV=/usr/local/bin/seal-dns.sh
ENV ENV=/usr/local/bin/seal-dns.sh
# === END DNS sinkhole ===
WORKDIR /workspace/cli

# Pre-download Go module dependencies
RUN mkdir -p /go && chmod -R 777 /go && go mod download || true

# Give agent ownership of workspace and dependencies
RUN chown -R agent:agent /workspace /logs /installed-agent /go

# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent

# Configure git for agent user
RUN git config --global user.email "agent@example.com" && \
    git config --global user.name "Agent"
