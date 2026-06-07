FROM python:3.12-slim@sha256:804ddf3251a60bbf9c92e73b7566c40428d54d0e79d3428194edf40da6521286
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace /logs/verifier /logs/agent/sessions /installed-agent
WORKDIR /workspace

RUN git init /workspace/repo && \
    cd /workspace/repo && \
    git remote add origin https://github.com/peteromallet/dataclaw.git && \
    git fetch --depth=1 origin 262041c088fd862d61db9cb3a0778e57bbba5ccf && \
    git checkout FETCH_HEAD

RUN cd /workspace/repo && \
    pip install --no-cache-dir \
      PyYAML==6.0.3 \
      Pygments==2.20.0 \
      annotated-doc==0.0.4 \
      anyio==4.13.0 \
      certifi==2026.2.25 \
      click==8.3.2 \
      filelock==3.29.0 \
      fsspec==2026.3.0 \
      h11==0.16.0 \
      hf-xet==1.4.3 \
      httpcore==1.0.9 \
      httpx==0.28.1 \
      huggingface_hub==1.11.0 \
      idna==3.12 \
      markdown-it-py==4.0.0 \
      mdurl==0.1.2 \
      packaging==26.1 \
      rich==15.0.0 \
      shellingham==1.5.4 \
      tqdm==4.67.3 \
      typer==0.24.1 \
      typing_extensions==4.15.0 && \
    pip install --no-cache-dir -e .

RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Claude Code requires non-root user for --dangerously-skip-permissions
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace && \
    chmod -R 777 /logs /installed-agent

# Mark repo as safe directory for the agent user
RUN git config --global --add safe.directory /workspace/repo

USER agent

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/home/agent/.local/bin:$PATH"

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
WORKDIR /workspace/repo
