FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    software-properties-common \
    gnupg \
    build-essential \
    tmux \
    asciinema \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.13 \
        python3.13-venv \
        python3.13-dev \
    && rm -rf /var/lib/apt/lists/*

# homeassistant>=2026.2.0b0 (in requirements_dev.txt) requires Python >=3.13.2;
# Ubuntu 24.04 ships only Python 3.12, so use the deadsnakes 3.13 build for the venv.
RUN python3.13 -m venv /venv
ENV PATH="/venv/bin:$PATH"

RUN pip install --upgrade pip setuptools wheel

WORKDIR /workspace
RUN git clone https://github.com/raman325/lock_code_manager.git /workspace/lock_code_manager \
    && cd /workspace/lock_code_manager \
    && git checkout de0c2b8034dc0a4f8cb44fe7b1a2dc602c68601e

WORKDIR /workspace/lock_code_manager

RUN pip install -r requirements_dev.txt
RUN pip install -r requirements_test.txt
RUN pip install pytest-cov pytest-xdist

ENV PYTHONPATH="/workspace/lock_code_manager:$PYTHONPATH"

RUN git config --global user.email "agent@example.com" \
    && git config --global user.name "Agent"

RUN mkdir -p /workspace /logs/verifier /installed-agent \
    && chown -R root:root /installed-agent

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /workspace/lock_code_manager && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /workspace/lock_code_manager
