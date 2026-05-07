FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates unzip \
    python3 python3-pip python3-venv build-essential \
    tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install bun (required by the project)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Clone the repo at the base commit
RUN git clone https://github.com/Nagi-ovo/gemini-voyager.git /workspace/repo
WORKDIR /workspace/repo
RUN git checkout 4e9d91695130a0dcde1c1f93cf41151c42e6ea52

# Install project dependencies
RUN bun install

# Set up workspace directories
RUN mkdir -p /workspace /logs/verifier

# Configure git
RUN git config --global user.email "agent@harbor.dev" && \
    git config --global user.name "Harbor Agent"

ENV PYTHONPATH="/workspace:${PYTHONPATH}"
