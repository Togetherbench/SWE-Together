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

# Create log directory for verifier output
RUN mkdir -p /logs/verifier

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /workspace/desloppify

# Do NOT include test scripts or solutions in the image
