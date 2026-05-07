FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates unzip xz-utils \
    python3 python3-pip python3-venv build-essential \
    tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install PyYAML for manifest parsing
RUN pip3 install --break-system-packages pyyaml

# Install Bun (system-wide, not in /root/)
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:$PATH"

RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone the repo at the base commit (pre-changes)
RUN git clone https://github.com/obsessiondb/rudel.git /workspace/rudel && \
    cd /workspace/rudel && \
    git checkout 799c99ecc34c1448efb6fd860fb09dc683eff29b

# Install dependencies
RUN cd /workspace/rudel && bun install

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs
USER agent
WORKDIR /workspace/rudel
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
