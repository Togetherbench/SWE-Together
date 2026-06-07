FROM python:3.12.8-slim-bookworm
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends git curl ca-certificates build-essential tmux jq bc sudo && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /logs/verifier /logs/agent/sessions
RUN git config --global user.email "agent@test.com" && git config --global user.name "Test Agent" && git config --global --add safe.directory /workspace && git config --global --add safe.directory /opt/origin.git

# Fetch repo with full history
RUN git init /tmp/repo && cd /tmp/repo && git remote add upstream https://github.com/segin/arr-monitor.git && git fetch upstream && git checkout -b main eba91a1905745415a4f4d5a91e7e246829cda566 && git branch feature-add-new-processes-flag 92cd2ecc0ba5d3dde8e97857d7c77e0f1569489f && git branch ignore-nfo-and-dll-transfers 4b1c6c197bece661c04aa6df85218871b244c9a8 && git remote remove upstream

# Create PR #4 branch with a conflicting change (adds executables to ignore list)
# This creates a multi-line conflict with PR #3's .nfo addition
RUN cd /tmp/repo && git checkout -b fix-ignore-exe-extension 26a9cb0c855fc32b21141d69f4944911e556382f \
    && python3 -c "f=open('arr-monitor.py','r');c=f.read();f.close();c=c.replace(\"    '.zip', '.dll'\n}\",\"    '.zip', '.dll',\n    # Executable and installer formats\n    '.exe', '.msi'\n}\");f=open('arr-monitor.py','w');f.write(c);f.close()" \
    && git add arr-monitor.py && git commit -m "Add executable formats (.exe, .msi) to ignored extensions" && git checkout main

# Create bare remote
RUN git clone --bare /tmp/repo /opt/origin.git && rm -rf /tmp/repo

# Clone to workspace
RUN rm -rf /workspace && git clone /opt/origin.git /workspace

# Create local tracking branches
RUN git -C /workspace checkout main && git -C /workspace branch --set-upstream-to=origin/main main && git -C /workspace checkout -b feature-add-new-processes-flag origin/feature-add-new-processes-flag && git -C /workspace checkout -b ignore-nfo-and-dll-transfers origin/ignore-nfo-and-dll-transfers && git -C /workspace checkout -b fix-ignore-exe-extension origin/fix-ignore-exe-extension && git -C /workspace checkout main

# Install deps
RUN pip install --no-cache-dir psutil==6.1.1

# Mock gh CLI
COPY gh /usr/local/bin/gh
RUN chmod +x /usr/local/bin/gh

# Non-root user for Claude Code
RUN useradd -m -s /bin/bash -u 1002 agent && chown -R agent:agent /workspace /opt/origin.git /logs
RUN echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent
# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/home/agent/.local/bin:$PATH"
RUN git config --global user.email "agent@test.com" && git config --global user.name "Test Agent" && git config --global --add safe.directory /workspace && git config --global --add safe.directory /opt/origin.git
WORKDIR /workspace

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
