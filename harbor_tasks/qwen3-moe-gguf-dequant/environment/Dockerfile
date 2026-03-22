FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    build-essential \
    cmake \
    tmux \
    asciinema \
    && rm -rf /var/lib/apt/lists/*

# Create workspace and log directories
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone the target repo at the base commit (IQ3_XXS already exists with test infrastructure)
RUN git clone https://github.com/woct0rdho/transformers-qwen3-moe-fused.git /workspace && \
    git checkout 1c5169714752d9e21a9bf30bbbae3657d7954a91

# Build libggml from llama.cpp (CPU-only) for test verification
# Using the same commit referenced in the test file
RUN git clone https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp && \
    cd /tmp/llama.cpp && \
    git checkout e54d41befcc1575f4c898c5ff4ef43970cead75f && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=OFF -DLLAMA_CURL=OFF -DBUILD_SHARED_LIBS=ON && \
    cmake --build build --target ggml -j$(nproc) && \
    find build -name "libggml*.so*" -exec cp {} /usr/local/lib/ \; && \
    ldconfig && \
    rm -rf /tmp/llama.cpp

# Install Python dependencies (CPU-only PyTorch)
RUN pip install --no-cache-dir \
    torch --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir numpy gguf

# Modify test_gguf_dequant.py for Linux/CPU environment
# 1. Replace Windows DLL path with Linux shared library path
# 2. Change device from "cuda" to "cpu"
RUN sed -i 's/device = "cuda"/device = "cpu"/' test_gguf_dequant.py && \
    sed -i '/dll_path/c\    dll_path = "/usr/local/lib/libggml.so"' test_gguf_dequant.py

# Synthesize buggy state: replace working IQ3_XXS with a buggy version
# (alignment issues, uses F.embedding). Script is deleted after running.
COPY synthesize_buggy_state.py /tmp/synthesize_buggy_state.py
RUN python3 /tmp/synthesize_buggy_state.py && rm /tmp/synthesize_buggy_state.py

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    cd /workspace && git add -A && git commit -m "initial workspace state"

WORKDIR /workspace
