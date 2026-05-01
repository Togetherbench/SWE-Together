FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b
ARG REBUILD_TOKEN=v042-20260430  # cache-bust to force rebuild on top of new base layers

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3-pip \
    git \
    curl \
    ca-certificates \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Make python3.12 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1

# Clone the repo at commit 295d3215 — the last commit before the session that
# implemented the generic language framework (2026-02-20T16:59:52Z).
# At this commit:
#   - generic.py does NOT exist (no generic language plugins yet)
#   - No go/rust/ruby/swift/kotlin language plugins
#   - No register_detector() in registry.py
#   - No register_scoring_policy() in scoring policy core.py
#   - No refresh_detector_tools() in narrative _constants.py
#   - No langs command
#   - No test_generic_plugin.py
# The agent must implement all of these from the instruction plan.
RUN git init /workspace/desloppify && \
    cd /workspace/desloppify && \
    git remote add origin https://github.com/peteromallet/desloppify.git && \
    git fetch --depth=1 origin 295d32158be25d8424bc397e4cd43cbf498eb956 && \
    git checkout FETCH_HEAD

# Install the project and its dependencies with pinned versions
RUN cd /workspace/desloppify && \
    python3 -m pip install --break-system-packages --no-cache-dir \
        Pillow==10.4.0 \
        setuptools==75.8.0 && \
    python3 -m pip install --break-system-packages --no-cache-dir -e .

# Install optional extras used by the project
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        PyYAML==6.0.2 \
        bandit==1.8.3 \
        defusedxml==0.7.1

# Install dev/test tooling
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        pytest==8.3.4 \
        ruff==0.9.7 \
        mypy==1.14.1

# Commit the initial state so git diff can measure the agent's changes
RUN cd /workspace/desloppify && \
    git config user.email "harbor@benchmark" && \
    git config user.name "Harbor" && \
    git add -A && \
    git commit --allow-empty -m 'initial workspace state'

# Verify the test suite passes on the initial state
RUN cd /workspace/desloppify && python3 -m pytest desloppify/tests/ -x -q --tb=short 2>&1 || true

# Verify the CLI is available
RUN cd /workspace/desloppify && python3 -m desloppify --help > /dev/null 2>&1 || true

# Create log directories for verifier and agent output
RUN mkdir -p /logs/verifier /logs/agent/sessions

# Remove any AGENTS.md / CLAUDE.md that could block or confuse the agent
RUN rm -f /workspace/desloppify/AGENTS.md /workspace/desloppify/CLAUDE.md \
         /workspace/desloppify/.claude/settings.json

# Create non-root user (Claude Code refuses --dangerously-skip-permissions as root)
# Use uid/gid 1002 to match the Harbor runner's host worker user for bind mounts
RUN useradd -m -s /bin/bash -u 1002 agent && \
    chown -R agent:agent /workspace && \
    mkdir -p /home/agent/.local/bin /logs/verifier /logs/agent/sessions && \
    chown -R agent:agent /home/agent /logs

# Pre-install Claude Code CLI as the non-root user
# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent
# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Configure git for agent user
RUN cd /workspace/desloppify && \
    git config user.email "agent@benchmark" && \
    git config user.name "Agent"

WORKDIR /workspace/desloppify

# Do NOT include test scripts or solutions in the image
