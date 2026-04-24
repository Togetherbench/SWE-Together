FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3-pip \
    git \
    ca-certificates \
    curl \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Make python3.12 the default python3
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 1 && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.12 1

# Clone the repo at commit eba4ad1c — the last commit BEFORE zone classification
# was added. This commit has narrative bug fixes but no zone infrastructure.
# The zone classification system (zones.py, zone_cmd.py, lang integration,
# CLI wiring, scoring integration) was added in f96b6cd0.
RUN git init /workspace/desloppify && \
    cd /workspace/desloppify && \
    git remote add origin https://github.com/peteromallet/desloppify.git && \
    git fetch --depth=1 origin eba4ad1cc33f6a6e94588c8ac3ee69450c603db4 && \
    git checkout FETCH_HEAD

# Install the project and its dependencies
RUN cd /workspace/desloppify && \
    python3 -m pip install --break-system-packages --no-cache-dir \
        Pillow==10.4.0 \
        setuptools==75.8.0 && \
    python3 -m pip install --break-system-packages --no-cache-dir -e .

# Install optional extras used across the project
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        PyYAML==6.0.2

# Install dev/test tooling
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        pytest==8.3.4

# Remove any AGENTS.md / CLAUDE.md that could block or confuse agents
RUN rm -f /workspace/desloppify/AGENTS.md /workspace/desloppify/CLAUDE.md /workspace/desloppify/.claude*

# Commit the initial state so git diff can measure the agent's changes
RUN cd /workspace/desloppify && \
    git config user.email "harbor@benchmark" && \
    git config user.name "Harbor" && \
    git add -A && \
    git commit --allow-empty -m 'initial workspace state'

# Verify the CLI is available
RUN cd /workspace/desloppify && python3 -m desloppify --help > /dev/null 2>&1 || true

# Create log directory for verifier output
RUN mkdir -p /logs/verifier

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/desloppify

# Do NOT include test scripts or solutions in the image
