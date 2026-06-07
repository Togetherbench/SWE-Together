FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install bun to /usr/local so it's accessible to the agent user
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone repo at base commit (pre-fix state)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /opt/gemini-voyager \
    && cd /opt/gemini-voyager \
    && git checkout 1f42255

WORKDIR /opt/gemini-voyager

# Install project dependencies
RUN bun install

ENV PYTHONPATH="/opt/gemini-voyager"
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent" \
    && mkdir -p /workspace /logs/verifier

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /opt/gemini-voyager
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
WORKDIR /opt/gemini-voyager
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
