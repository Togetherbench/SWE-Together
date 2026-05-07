FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Clone the repo at the base commit (v3.0.0 release)
RUN git clone https://github.com/Mathews-Tom/no-magic.git /home/user/no-magic && \
    cd /home/user/no-magic && \
    git checkout 9a876115d119638e2d2dcd09028001ae258563d7

# Install Python deps if a requirements.txt or pyproject.toml is present.
# no-magic at 9a87611 is stdlib-only by design, but this guard keeps the
# Dockerfile robust if future commits add a requirements file.
RUN cd /home/user/no-magic && \
    if [ -f requirements.txt ]; then pip install --break-system-packages -r requirements.txt; \
    elif [ -f pyproject.toml ] || [ -f setup.py ]; then pip install --break-system-packages -e .; \
    else echo "no requirements file present; skipping pip install"; fi

# Remove the target file so the agent must implement it from scratch.
# Also remove related video/asset files.
RUN rm -f /home/user/no-magic/01-foundations/microtokenizer.py \
    /home/user/no-magic/videos/previews/microtokenizer.gif \
    /home/user/no-magic/videos/scenes/scene_microtokenizer.py

ENV PYTHONPATH=/home/user/no-magic
ENV PYTHONUNBUFFERED=1

RUN mkdir -p /workspace /logs/verifier

# Create agent user and set permissions
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /installed-agent \
    && chown -R agent:agent /workspace /installed-agent /logs /home/user/no-magic

USER agent
WORKDIR /home/user/no-magic

# Set up git config for agent user (lands in /home/agent/.gitconfig)
RUN git config --global user.email "agent@example.com" && \
    git config --global user.name "Harbor Agent"
