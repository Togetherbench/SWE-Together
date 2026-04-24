FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    git \
    curl \
    ca-certificates \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Clone the repo at the initial release commit — before any tests were committed
RUN git init /workspace/dataclaw && \
    cd /workspace/dataclaw && \
    git remote add origin https://github.com/banodoco/dataclaw.git && \
    git fetch --depth=1 origin cda7e501452c450a7a8f4cb63b324e32a14247ce && \
    git checkout FETCH_HEAD

# Synthesize the buggy/incomplete state: remove the tests directory
RUN rm -rf /workspace/dataclaw/tests

# Remove any AGENTS.md or CLAUDE.md that might interfere with agent behavior
RUN rm -f /workspace/dataclaw/AGENTS.md /workspace/dataclaw/CLAUDE.md

# Install project dependencies (no GPU needed — pure Python)
RUN cd /workspace/dataclaw && \
    pip install --break-system-packages --no-cache-dir -e ".[dev]"

# Install additional test dependencies
RUN pip install --break-system-packages --no-cache-dir \
    pytest==8.3.4 \
    pytest-cov==6.0.0 \
    pytest-timeout==2.3.1

# Install huggingface_hub (optional dep referenced in the code)
RUN pip install --break-system-packages --no-cache-dir \
    huggingface_hub==0.27.1 || true

# Configure git identity so commits work inside the container
RUN git config --global user.email "harbor@benchmark" && \
    git config --global user.name "Harbor"

# Commit the synthesized state (no tests) as the baseline
RUN cd /workspace/dataclaw && \
    git add -A && \
    git commit --allow-empty -m "initial workspace state"

# Create log directories (verifier + agent sessions used by Harbor runner)
RUN mkdir -p /logs/verifier /logs/agent/sessions

# Set PYTHONPATH so dataclaw is importable
ENV PYTHONPATH="/workspace/dataclaw"

# Create non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs && \
    cp /root/.gitconfig /home/agent/.gitconfig && \
    chown agent:agent /home/agent/.gitconfig

# Pre-install Claude Code CLI v2.1.108 (pinned for reproducibility — harness
# version is part of the image hash). Harbor's install-claude-code.sh detects
# `claude` in PATH and skips runtime install when this is present.
# Harbor install.sh target dir (fix for mkdir-as-nonroot bug)
RUN mkdir -p /installed-agent && chown agent:agent /installed-agent
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- 2.1.108
ENV PATH="/home/agent/.local/bin:$PATH"

WORKDIR /workspace/dataclaw
