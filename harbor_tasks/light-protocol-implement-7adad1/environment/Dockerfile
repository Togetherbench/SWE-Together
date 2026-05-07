FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates python3 python3-pip python3-venv \
    build-essential pkg-config libssl-dev tmux asciinema \
    && rm -rf /var/lib/apt/lists/*

# Install Rust toolchain matching the repo's rust-toolchain.toml
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.90.0
ENV PATH="/root/.cargo/bin:${PATH}"

# Install tree-sitter for Rust AST parsing in the verifier
RUN pip3 install --break-system-packages tree-sitter==0.23.2 tree-sitter-rust==0.23.2

# Clone the repo at the base commit (2026-02-17, pre-idempotent-flag feature)
RUN git clone https://github.com/Lightprotocol/light-protocol.git /home/user/light-protocol \
    && cd /home/user/light-protocol \
    && git checkout f7a3defb5095dfb82cf05cbc16701b6edb1054e3

# Note: workspace has an SSH submodule (external/photon) that cannot be cloned
# in this environment. cargo test -p light-sdk-macros only needs the macro
# crate and its public deps, so it builds fine without the submodule.

RUN mkdir -p /workspace /logs/verifier
# Allow Harbor to install claude-code at runtime
RUN mkdir -p /installed-agent && chown root:root /installed-agent
WORKDIR /home/user/light-protocol
