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
RUN git init /tmp/llama.cpp && \
    cd /tmp/llama.cpp && \
    git remote add origin https://github.com/ggml-org/llama.cpp.git && \
    git fetch --depth=1 origin e54d41befcc1575f4c898c5ff4ef43970cead75f && \
    git checkout FETCH_HEAD && \
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
RUN echo 'IyEvdXNyL2Jpbi9lbnYgcHl0aG9uMwoiIiJTeW50aGVzaXplIGJ1Z2d5IGluaXRpYWwgc3RhdGUgZm9yIHRoZSBiZW5jaG1hcmsgdGFzay4KClJlcGxhY2VzIHRoZSB3b3JraW5nIElRM19YWFMgZGVxdWFudGl6YXRpb24gZnVuY3Rpb24gd2l0aCBhIGJ1Z2d5IHZlcnNpb24KdGhhdCBoYXMgYWxpZ25tZW50IGlzc3VlcyBhbmQgdXNlcyBGLmVtYmVkZGluZyBpbnN0ZWFkIG9mIGRpcmVjdCBpbmRleGluZy4KVGhpcyBmaWxlIGlzIGRlbGV0ZWQgYWZ0ZXIgcnVubmluZyBkdXJpbmcgRG9ja2VyIGJ1aWxkLgoiIiIKaW1wb3J0IGFzdAppbXBvcnQgcmUKaW1wb3J0IHRleHR3cmFwCgpERVFVQU5UX0ZJTEUgPSAiL3dvcmtzcGFjZS9xd2VuM19tb2VfZnVzZWQvcXVhbnRpemVfZ2d1Zi9kZXF1YW50LnB5IgoKd2l0aCBvcGVuKERFUVVBTlRfRklMRSwgInIiKSBhcyBmOgogICAgY29udGVudCA9IGYucmVhZCgpCgojIFRoZSBmaWxlIGF0IGNvbW1pdCAxYzUxNjk3IGhhcyBhIHdvcmtpbmcgSVEzX1hYUy4KIyBSZXBsYWNlIGl0IHdpdGggYSBidWdneSBzdHViIHRoYXQgbWlycm9ycyB0aGUgaW5pdGlhbCBzZXNzaW9uIHN0YXRlOgojIC0gTm8gLmNsb25lKCkgYmVmb3JlIC52aWV3KHRvcmNoLmludDMyKSAtPiBhbGlnbm1lbnQgUnVudGltZUVycm9yCiMgLSBVc2VzIEYuZW1iZWRkaW5nIGluc3RlYWQgb2YgZGlyZWN0IHRlbnNvciBpbmRleGluZwojIC0gV3Jvbmcgc3BsaXRfYmxvY2tfZGltcyAobWlzc2luZyB0aGUgMzItYnl0ZSBzcGxpdCBmb3Igc2NhbGVzKQpidWdneV9pcTNfeHhzID0gdGV4dHdyYXAuZGVkZW50KCIiIlwKICAgIGRlZiBkZXF1YW50aXplX2Jsb2Nrc19JUTNfWFhTKGJsb2NrcywgYmxvY2tfc2l6ZSwgdHlwZV9zaXplLCBkdHlwZT1Ob25lKToKICAgICAgICBuX2Jsb2NrcyA9IGJsb2Nrcy5zaGFwZVswXQoKICAgICAgICBkLCBxcywgc2NhbGVzID0gc3BsaXRfYmxvY2tfZGltcyhibG9ja3MsIDIsIDY0KQoKICAgICAgICBkID0gZC52aWV3KHRvcmNoLmZsb2F0MTYpLnRvKGR0eXBlKQogICAgICAgICMgQlVHOiB2aWV3aW5nIHVuYWxpZ25lZCB0ZW5zb3IgYXMgaW50MzIgd2l0aG91dCBjbG9uZSBjYXVzZXMgUnVudGltZUVycm9yCiAgICAgICAgc2NhbGVzID0gc2NhbGVzLnZpZXcodG9yY2guaW50MzIpCgogICAgICAgIGRiID0gZCAqICgwLjUgKyAoKHNjYWxlcyA+PiAyOCkgJiAweEYpLnRvKGR0eXBlKSkgKiAwLjUKICAgICAgICBkYiA9IGRiLnJlc2hhcGUobl9ibG9ja3MsIC0xLCAxLCAxKQoKICAgICAgICAjIHNpZ25zCiAgICAgICAgc2hpZnRzID0gdG9yY2gudGVuc29yKFswLCA3LCAxNCwgMjFdLCBkZXZpY2U9ZC5kZXZpY2UsIGR0eXBlPXRvcmNoLmludDMyKS5yZXNoYXBlKDEsIDEsIDQpCiAgICAgICAgc2lnbnMgPSAoc2NhbGVzLnJlc2hhcGUobl9ibG9ja3MsIC0xLCAxKSA+PiBzaGlmdHMpICYgMHg3RgoKICAgICAgICBzaWducyA9IHRvcmNoLm5uLmZ1bmN0aW9uYWwuZW1iZWRkaW5nKHNpZ25zLCBLU0lHTlNfSVEyX1hYUy5mbG9hdCgpLnRvKGQuZGV2aWNlKSkKCiAgICAgICAgc2hpZnRzX2JpdHMgPSB0b3JjaC5hcmFuZ2UoOCwgZGV2aWNlPWQuZGV2aWNlLCBkdHlwZT10b3JjaC51aW50OCkucmVzaGFwZSgxLCAxLCAxLCA4KQogICAgICAgIHNpZ25zID0gKHNpZ25zLnRvKHRvcmNoLnVpbnQ4KS51bnNxdWVlemUoLTEpID4+IHNoaWZ0c19iaXRzKSAmIDEKICAgICAgICBzaWducyA9IHRvcmNoLndoZXJlKAogICAgICAgICAgICBzaWducyA9PSAwLCB0b3JjaC50ZW5zb3IoMS4wLCBkdHlwZT1kdHlwZSwgZGV2aWNlPWQuZGV2aWNlKSwgdG9yY2gudGVuc29yKC0xLjAsIGR0eXBlPWR0eXBlLCBkZXZpY2U9ZC5kZXZpY2UpCiAgICAgICAgKQoKICAgICAgICAjIGdyaWQKICAgICAgICBncmlkX3ZhbCA9IHRvcmNoLm5uLmZ1bmN0aW9uYWwuZW1iZWRkaW5nKHFzLmxvbmcoKSwgR1JJRF9JUTNfWFhTLnRvKGR0eXBlPWR0eXBlLCBkZXZpY2U9ZC5kZXZpY2UpKQogICAgICAgIGdyaWRfdmFsID0gZ3JpZF92YWwucmVzaGFwZShuX2Jsb2NrcywgLTEsIDQsIDgpCgogICAgICAgIHJldHVybiAoZGIgKiBncmlkX3ZhbCAqIHNpZ25zKS5yZXNoYXBlKG5fYmxvY2tzLCAyNTYpCgogICAgIiIiKQoKIyBSZXBsYWNlIHRoZSB3b3JraW5nIElRM19YWFMgZnVuY3Rpb24gd2l0aCB0aGUgYnVnZ3kgc3R1YgojIE1hdGNoIGZyb20gZnVuY3Rpb24gZGVmaW5pdGlvbiB0byB0aGUgbmV4dCBibGFuayBsaW5lIGJlZm9yZSBkZXF1YW50aXplX2Z1bmN0aW9ucyBkaWN0CnBhdHRlcm4gPSByImRlZiBkZXF1YW50aXplX2Jsb2Nrc19JUTNfWFhTXCguKj9cbig/PVxuKD86ZGVmIHxkZXF1YW50aXplX2Z1bmN0aW9ucykpIgpjb250ZW50ID0gcmUuc3ViKHBhdHRlcm4sIGJ1Z2d5X2lxM194eHMsIGNvbnRlbnQsIGZsYWdzPXJlLkRPVEFMTCkKCndpdGggb3BlbihERVFVQU5UX0ZJTEUsICJ3IikgYXMgZjoKICAgIGYud3JpdGUoY29udGVudCkKCiMgVmVyaWZ5IHRoZSBzeW50aGVzaXMgd29ya2VkCndpdGggb3BlbihERVFVQU5UX0ZJTEUpIGFzIGY6CiAgICBzb3VyY2UgPSBmLnJlYWQoKQp0cmVlID0gYXN0LnBhcnNlKHNvdXJjZSkKZnVuY3MgPSBbbi5uYW1lIGZvciBuIGluIGFzdC53YWxrKHRyZWUpIGlmIGlzaW5zdGFuY2UobiwgYXN0LkZ1bmN0aW9uRGVmKV0KcHJpbnQoIkZ1bmN0aW9ucyBmb3VuZDoiLCBmdW5jcykKYXNzZXJ0ICJkZXF1YW50aXplX2Jsb2Nrc19JUTNfWFhTIiBpbiBmdW5jcywgIklRM19YWFMgZnVuY3Rpb24gbWlzc2luZyEiCmFzc2VydCAiZGVxdWFudGl6ZV9ibG9ja3NfSVEzX1MiIG5vdCBpbiBmdW5jcywgIklRM19TIHNob3VsZCBub3QgZXhpc3QgeWV0ISIKYXNzZXJ0ICJGLmVtYmVkZGluZyIgbm90IGluIHNvdXJjZSBvciAidG9yY2gubm4uZnVuY3Rpb25hbC5lbWJlZGRpbmciIGluIHNvdXJjZSwgIkJ1Z2d5IEYuZW1iZWRkaW5nIHNob3VsZCBiZSBwcmVzZW50IgpwcmludCgiU3ludGhlc2lzIGNoZWNrIHBhc3NlZCAtIGJ1Z2d5IElRM19YWFMgaW5zdGFsbGVkLCBubyBvdGhlciBJUSBmdW5jdGlvbnMgcHJlc2VudCIpCg==' | base64 -d > /tmp/synthesize_buggy_state.py
RUN python3 /tmp/synthesize_buggy_state.py && rm /tmp/synthesize_buggy_state.py

# Remove any AGENTS.md / CLAUDE.md that might constrain agent behavior
RUN rm -f /workspace/AGENTS.md /workspace/CLAUDE.md

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent" && \
    cd /workspace && git add -A && git commit -m "initial workspace state"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Create non-root user for Claude Code (--dangerously-skip-permissions requires non-root)
RUN useradd -m -s /bin/bash agent && \
    mkdir -p /home/agent/.local/bin /home/agent/.local/share/claude && \
    cp -rL /root/.local/share/claude/versions /home/agent/.local/share/claude/versions && \
    ln -sf /home/agent/.local/share/claude/versions/* /home/agent/.local/bin/claude && \
    chown -R agent:agent /home/agent/.local /workspace /logs && \
    git config --global --add safe.directory /workspace

ENV PATH="/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV HOME="/home/agent"
ENV CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000
USER agent

WORKDIR /workspace
