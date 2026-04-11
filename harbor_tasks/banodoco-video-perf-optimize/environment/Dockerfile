FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies + Node.js 20 (via NodeSource)
RUN apt-get update -o Acquire::AllowInsecureRepositories=true \
    -o Acquire::AllowDowngradeToInsecureRepositories=true \
    && apt-get install -y --no-install-recommends --allow-unauthenticated \
    git \
    curl \
    ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh \
    && bash /tmp/nodesource_setup.sh \
    && apt-get install -y --allow-unauthenticated nodejs \
    && rm -rf /var/lib/apt/lists/* /tmp/nodesource_setup.sh

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone xliry/banodoco-wrapped at commit 13a06f8
RUN git init /workspace/banodoco-wrapped && \
    cd /workspace/banodoco-wrapped && \
    git remote add origin https://github.com/xliry/banodoco-wrapped.git && \
    git fetch --depth=1 origin 13a06f8d91c6eece10bf42c4218c4fe6fa83636b && \
    git checkout FETCH_HEAD

# Install npm dependencies (includes typescript, tsx, vite, recharts, framer-motion)
RUN cd /workspace/banodoco-wrapped && npm install

# Remove any AGENTS.md / CLAUDE.md that could interfere with agent behavior
RUN rm -f /workspace/banodoco-wrapped/AGENTS.md /workspace/banodoco-wrapped/CLAUDE.md

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Create non-root user for Claude Code (refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash agent && \
    chown -R agent:agent /workspace /logs && \
    mkdir -p /tests && chown agent:agent /tests

# Pre-install Claude Code CLI as non-root user
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/agent/.local/bin:$PATH"

WORKDIR /workspace/banodoco-wrapped
