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
RUN git clone https://github.com/xliry/banodoco-wrapped.git /workspace/banodoco-wrapped && \
    cd /workspace/banodoco-wrapped && \
    git checkout 13a06f8

# Install npm dependencies (includes typescript, tsx, vite, recharts, framer-motion)
RUN cd /workspace/banodoco-wrapped && npm install

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

WORKDIR /workspace/banodoco-wrapped
