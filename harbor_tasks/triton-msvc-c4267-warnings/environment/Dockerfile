FROM python:3.12-slim@sha256:804ddf3251a60bbf9c92e73b7566c40428d54d0e79d3428194edf40da6521286
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates build-essential tmux \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /workspace /logs/verifier
WORKDIR /workspace

# Clone triton at the specific commit (blobless for speed)
RUN git clone --filter=blob:none --no-checkout https://github.com/triton-lang/triton.git /workspace/triton && \
    cd /workspace/triton && \
    git checkout 9a6af86c948375496f2d79d8a58e9f54ab65a955

# === BEGIN corpus-wide git-seal (PR #212) ===
# Inserted AFTER last `git checkout <BASE>` (HEAD must be detached before refs deleted).
RUN cd /workspace/triton && \
    git checkout --detach HEAD && \
    (git remote remove origin 2>/dev/null || true) && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    (git gc --prune=now --aggressive || true) && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===


RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/root/.local/bin:$PATH"

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
WORKDIR /workspace/triton
