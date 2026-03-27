FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 (required for TypeScript compilation and type checking)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Create workspace and verifier log directory
RUN mkdir -p /workspace /logs/verifier

# Clone banodoco/reigh at the commit just before the TimelineModeContent refactor.
# At this commit:
#   - TimelineModeContent.tsx exists as a pure pass-through of 65 props
#   - Timeline.tsx has dead props: hookData, pairPrompts, enhancedPrompts, EMPTY_ENHANCED_PROMPTS
#   - ShotImagesEditor.tsx routes through TimelineModeContent to reach Timeline
RUN git clone https://github.com/banodoco/reigh.git /workspace/reigh && \
    cd /workspace/reigh && \
    git checkout 65e12652c1b36264a9db20a5745e5861df669de1

# Install project dependencies (needed for TypeScript compilation checks)
# Uses package-lock.json for reproducible installs
RUN cd /workspace/reigh && npm ci --legacy-peer-deps 2>&1 | tail -5 || \
    npm install --legacy-peer-deps 2>&1 | tail -5

# Configure git identity for agent use
RUN git config --global user.email "agent@benchmark.test" && \
    git config --global user.name "Harbor Agent"

# Commit the initial workspace state
RUN cd /workspace/reigh && \
    git add -A && \
    git commit --allow-empty -m "initial workspace state"

WORKDIR /workspace/reigh
