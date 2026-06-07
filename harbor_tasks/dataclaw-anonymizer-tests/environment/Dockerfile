FROM python:3.12.8-slim
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace /logs/verifier /logs/agent/sessions
WORKDIR /workspace

RUN git init /workspace/repo && \
    cd /workspace/repo && \
    git remote add origin https://github.com/peteromallet/dataclaw.git && \
    git fetch --depth=1 origin 3c0991467af69675afa948c3ada45475a772fbeb && \
    git checkout FETCH_HEAD

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


RUN cd /workspace/repo && \
    pip install --no-cache-dir -e . 2>/dev/null || \
    pip install --no-cache-dir -r requirements.txt 2>/dev/null || true && \
    pip install --no-cache-dir pytest==8.3.4

# Create non-root user for Claude Code
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs

RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    git config --global --add safe.directory /workspace/repo

# Create 'main' branch at current state (old anonymizer code)
RUN cd /workspace/repo && git checkout -b main

# Copy modified files for windows branch
COPY windows_anonymizer.py /tmp/windows_anonymizer.py
COPY windows_test_anonymizer.py /tmp/windows_test_anonymizer.py

# Create 'windows' branch with the partial Windows support implementation
RUN cd /workspace/repo && \
    git checkout -b windows && \
    cp /tmp/windows_anonymizer.py dataclaw/anonymizer.py && \
    cp /tmp/windows_test_anonymizer.py tests/test_anonymizer.py && \
    git add -A && \
    git commit -m "Add Windows path support and simplify anonymizer"

RUN chown -R agent:agent /workspace /logs && \
    chmod -R 777 /logs

# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/root/.local/bin:$PATH"

# Run as root so harbor volume mounts for /logs are writable

WORKDIR /workspace/repo
