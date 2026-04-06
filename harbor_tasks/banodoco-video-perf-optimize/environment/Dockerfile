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

# Clone xliry/banodoco-wrapped at commit 13a06f8 — the last commit before the
# user's session. At this commit:
# - TopGenerations.tsx renders ALL month rows at once (no virtualization)
# - ModelTrends.tsx starts with visibleCount=data.length (all data visible, no animation)
# - ModelTrends.tsx has constant STEP_MS=180 (no ease-out)
# - ModelTrends.tsx has no IntersectionObserver auto-play (requires manual Play click)
RUN git init /workspace/banodoco-wrapped && \
    cd /workspace/banodoco-wrapped && \
    git remote add origin https://github.com/xliry/banodoco-wrapped.git && \
    git fetch --depth=1 origin 13a06f8d91c6eece10bf42c4218c4fe6fa83636b && \
    git checkout FETCH_HEAD

# Install npm dependencies (includes typescript, tsx, vite, recharts, framer-motion)
RUN cd /workspace/banodoco-wrapped && npm install

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/banodoco-wrapped
