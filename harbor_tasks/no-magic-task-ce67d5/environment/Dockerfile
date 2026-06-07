FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Clone the repo at the base commit (v3.0.0 release)
RUN git clone https://github.com/Mathews-Tom/no-magic.git /home/user/no-magic && \
    cd /home/user/no-magic && \
    git checkout 9a876115d119638e2d2dcd09028001ae258563d7

# Install Python deps if a requirements.txt or pyproject.toml is present.
# no-magic at 9a87611 is stdlib-only by design, but this guard keeps the
# Dockerfile robust if future commits add a requirements file.
RUN cd /home/user/no-magic && \
    if [ -f requirements.txt ]; then pip install --break-system-packages -r requirements.txt; \
    elif [ -f pyproject.toml ] || [ -f setup.py ]; then pip install --break-system-packages -e .; \
    else echo "no requirements file present; skipping pip install"; fi

# Remove the target file so the agent must implement it from scratch.
# Also remove related video/asset files.
RUN rm -f /home/user/no-magic/01-foundations/microtokenizer.py \
    /home/user/no-magic/videos/previews/microtokenizer.gif \
    /home/user/no-magic/videos/scenes/scene_microtokenizer.py

ENV PYTHONPATH=/home/user/no-magic
ENV PYTHONUNBUFFERED=1

RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /home/user/no-magic

USER agent

# === BEGIN corpus-wide git-seal (PR #212) ===
# Prevent agent contamination via `git checkout main` / `git log origin/main` /
# `git cherry-pick <sha>`. Recipe: union of SWE-bench PR #471 +
# SWE-bench Pro strip_future_history.py. See bayes.net/swebench-hack/ for
# the exploit pattern; PR #212 for verification on pi-mono.
RUN cd /home/user/no-magic && \
    git remote remove origin 2>/dev/null || true && \
    git for-each-ref --format='delete %(refname)' refs/heads refs/remotes refs/tags | git update-ref --stdin && \
    rm -f .git/FETCH_HEAD .git/ORIG_HEAD .git/packed-refs && \
    git reflog expire --expire=now --all && \
    git gc --prune=now --aggressive && \
    BASE_TS=$(git show -s --format=%ci HEAD) && \
    AFTER_TS=$(date -d "$BASE_TS + 1 second" '+%Y-%m-%d %H:%M:%S') && \
    [ "$(git log --oneline --all --since="$AFTER_TS" | wc -l)" -eq 0 ] || { echo "LEAK: future commits reachable" >&2; exit 1; }
# === END corpus-wide git-seal ===
WORKDIR /home/user/no-magic

# Set up git config for agent user (lands in /home/agent/.gitconfig)
RUN git config --global user.email "agent@example.com" && \
    git config --global user.name "Harbor Agent"

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
