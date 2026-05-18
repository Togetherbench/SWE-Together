FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip xz-utils \
    python3 python3-pip python3-venv build-essential \
    tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Bun system-wide (required by this TypeScript project)
ENV BUN_INSTALL="/usr/local"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone the repo at the buggy commit (parent of the dot-reuse fix 23a513c)
# Aligns with reference_patch.json canonical hunks (file at v0.2.8/b44f338 was 1526 lines;
# patch context anchors to the 3625-line state at the fix's direct parent 66ad6e3).
# 2026-05-17: forced E2B template rebuild — cached template was built from a stale state.
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /app \
    && cd /app \
    && git checkout 66ad6e36eb151a5ef88beef777a69a7afdbf7d72

WORKDIR /app

# Install project dependencies
RUN bun i

# Round-5 fix (oracle audit #139): removed `RUN bun run typecheck` here —
# it consistently OOM-kills inside E2B's build container (`signal: killed`
# during typecheck), which prevented template rebuild after the round-2
# Dockerfile fix. The verifier doesn't depend on the baseline compiling
# (it grades the canonical patch's behavior), and the agent will surface
# compile errors naturally during its work. If runtime typecheck is needed,
# move it to test.sh.

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /app

USER agent
WORKDIR /app

# Configure git for the agent (after USER agent so it lands in agent's home)
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"
