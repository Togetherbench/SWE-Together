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
# (tests/ directory was included in cda7e501 but we remove it below to synthesize
# the pre-test baseline state the session started from)
RUN git clone https://github.com/banodoco/dataclaw.git /workspace/dataclaw && \
    cd /workspace/dataclaw && \
    git checkout cda7e501452c450a7a8f4cb63b324e32a14247ce

# Synthesize the buggy/incomplete state: remove the tests directory
# The session task is to write these tests from scratch
RUN rm -rf /workspace/dataclaw/tests

# Install project dependencies (no GPU needed — pure Python)
RUN cd /workspace/dataclaw && \
    pip install --break-system-packages --no-cache-dir -e ".[dev]"

# Install additional test dependencies
RUN pip install --break-system-packages --no-cache-dir \
    pytest==8.3.4 \
    pytest-cov==6.0.0

# Install huggingface_hub (optional dep referenced in the code)
RUN pip install --break-system-packages --no-cache-dir \
    huggingface_hub>=0.20.0 || true

# Configure git identity so commits work inside the container
RUN git config --global user.email "harbor@benchmark" && \
    git config --global user.name "Harbor"

# Commit the synthesized state (no tests) as the baseline
RUN cd /workspace/dataclaw && \
    git add -A && \
    git commit --allow-empty -m "initial workspace state"

# Create verifier log directory
RUN mkdir -p /logs/verifier

# Set PYTHONPATH so dataclaw is importable
ENV PYTHONPATH="/workspace/dataclaw"

WORKDIR /workspace/dataclaw
