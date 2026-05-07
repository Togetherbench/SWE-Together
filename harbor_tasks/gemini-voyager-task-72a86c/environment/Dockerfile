FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install bun (system-wide so the agent user can execute it)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/usr/local/bin:$PATH"

# Install Python YAML parser for test scripts
RUN pip3 install --break-system-packages pyyaml

# Clone repo at base commit (pre-feature state)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /workspace/gemini-voyager \
    && cd /workspace/gemini-voyager \
    && git checkout 38c33258f0ca3863e1b08fe65bf37a26352ac355

WORKDIR /workspace/gemini-voyager

# Install project dependencies
RUN bun install

RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs

USER agent
WORKDIR /workspace/gemini-voyager
