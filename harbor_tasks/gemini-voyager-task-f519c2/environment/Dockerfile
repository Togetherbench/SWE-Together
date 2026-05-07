FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install bun to /usr/local so it's accessible to the agent user
ENV BUN_INSTALL=/usr/local
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/usr/local/bin:${PATH}"

# Clone repo at base commit (pre-fix state)
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /opt/gemini-voyager \
    && cd /opt/gemini-voyager \
    && git checkout 1f42255

WORKDIR /opt/gemini-voyager

# Install project dependencies
RUN bun install

ENV PYTHONPATH="/opt/gemini-voyager"
RUN git config --global user.email "agent@harbor.dev" \
    && git config --global user.name "Harbor Agent" \
    && mkdir -p /workspace /logs/verifier

RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /opt/gemini-voyager
USER agent
WORKDIR /opt/gemini-voyager
RUN git config --global user.email "agent@harbor.dev" && git config --global user.name "Harbor Agent"
