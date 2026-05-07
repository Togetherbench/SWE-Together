FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip xz-utils python3 python3-pip python3-venv build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install bun system-wide so the agent user can execute it
ENV BUN_INSTALL="/usr/local"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone repo at pre-rename commit (parent of the session's commit)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /opt/gemini-voyager \
    && cd /opt/gemini-voyager \
    && git checkout 75c76ffc

WORKDIR /opt/gemini-voyager

# Install dependencies
RUN bun install

# Set up Python for verifier
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Create workspace directories
RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /opt/gemini-voyager /opt/venv

USER agent
WORKDIR /opt/gemini-voyager

# Set git identity for the agent (after USER agent so it lands in agent's home)
RUN git config --global user.email "agent@harbor.local" \
    && git config --global user.name "Harbor Agent"
