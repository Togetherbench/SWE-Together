FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip xz-utils python3 python3-pip python3-venv build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install bun system-wide so the agent user can execute it
ENV BUN_INSTALL="/usr/local"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone repo at pre-rename commit (parent of the session's commit)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /opt/gemini-voyager \
    && cd /opt/gemini-voyager \
    && git checkout 75c76ffc

WORKDIR /opt/gemini-voyager

# Install dependencies
RUN bun install

# Set up Python for verifier
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /opt/gemini-voyager /opt/venv

USER agent

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /opt/gemini-voyager && \
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
WORKDIR /opt/gemini-voyager

# Set git identity for the agent (after USER agent so it lands in agent's home)
RUN git config --global user.email "agent@harbor.local" \
    && git config --global user.name "Harbor Agent"
