FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip \
    python3 python3-pip python3-venv build-essential \
    tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install bun (required by the project)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Clone the repo at the base commit
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /workspace/repo

WORKDIR /workspace/repo
RUN git checkout 4e9d91695130a0dcde1c1f93cf41151c42e6ea52

# === BEGIN corpus-wide git-seal (PR #212) ===
# Inserted AFTER last `git checkout <BASE>` (HEAD must be detached before refs deleted).
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


# Install project dependencies
RUN bun install

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier

# Configure git
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"

ENV PYTHONPATH="/workspace:${PYTHONPATH}"
