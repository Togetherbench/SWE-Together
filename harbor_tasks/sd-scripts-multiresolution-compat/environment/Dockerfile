FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    tmux \
    asciinema \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Create workspace
RUN mkdir -p /workspace /logs/verifier

WORKDIR /workspace

# Clone sd-scripts at commit e21a773 (Support Anima model — the commit just before
# the user's local multi-resolution SD1/SDXL commit that starts this session).
RUN git init /workspace/sd-scripts && \
    cd /workspace/sd-scripts && \
    git remote add origin https://github.com/kohya-ss/sd-scripts.git && \
    git fetch --depth=1 origin e21a7736f8fdd2477836edf254105518beb9790e && \
    git checkout FETCH_HEAD

# Set up Python virtual environment
RUN python3 -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"
ENV VIRTUAL_ENV="/workspace/venv"

# Install CPU-only PyTorch and torchvision
RUN pip install --no-cache-dir \
    torch==2.6.0+cpu torchvision==0.21.0+cpu --index-url https://download.pytorch.org/whl/cpu

# Install sd-scripts dependencies (pinned to versions from requirements.txt)
RUN pip install --no-cache-dir \
    "accelerate==1.6.0" \
    "transformers==4.54.1" \
    "diffusers[torch]==0.32.1" \
    "ftfy==6.3.1" \
    "opencv-python-headless==4.10.0.84" \
    "einops==0.7.0" \
    "safetensors==0.4.5" \
    "toml==0.10.2" \
    "voluptuous==0.15.2" \
    "huggingface-hub==0.34.3" \
    "imagesize==1.4.1" \
    "lion-pytorch==0.2.3" \
    "schedulefree==1.4" \
    "pytorch-optimizer==3.9.0" \
    "prodigyopt==1.1.2" \
    "rich==14.1.0" \
    "sentencepiece==0.2.1" \
    "Pillow" \
    "tqdm" \
    "numpy" \
    "pytest" \
    "pytest-timeout"

# bitsandbytes may not fully work on CPU but is importable
RUN pip install --no-cache-dir bitsandbytes || true

# Synthesize the "last commit" state: enable multi-resolution for SD1/SDXL in strategy_sd.py.
# This adds multi_resolution=True calls and a load_latents_from_disk override —
# exactly the changes from the user's local commit (HEAD~ in the session).
RUN python3 - << 'PYEOF'
path = "/workspace/sd-scripts/library/strategy_sd.py"
with open(path, "r") as f:
    src = f.read()

# 1. Add "import numpy as np" before torch import
src = src.replace(
    "import torch\nfrom transformers import CLIPTokenizer",
    "import numpy as np\nimport torch\nfrom transformers import CLIPTokenizer",
)

# 2. Change is_disk_cached_latents_expected to pass multi_resolution=True
src = src.replace(
    "        return self._default_is_disk_cached_latents_expected(8, bucket_reso, npz_path, flip_aug, alpha_mask)",
    "        return self._default_is_disk_cached_latents_expected(8, bucket_reso, npz_path, flip_aug, alpha_mask, multi_resolution=True)",
)

# 3. Add load_latents_from_disk method before cache_batch_latents
load_method = '''
    def load_latents_from_disk(
        self, npz_path: str, bucket_reso: Tuple[int, int]
    ) -> Tuple[Optional[np.ndarray], Optional[List[int]], Optional[List[int]], Optional[np.ndarray], Optional[np.ndarray]]:
        return self._default_load_latents_from_disk(8, npz_path, bucket_reso)

'''
src = src.replace(
    "    # TODO remove circular dependency for ImageInfo\n    def cache_batch_latents(",
    load_method + "    # TODO remove circular dependency for ImageInfo\n    def cache_batch_latents(",
)

# 4. Change _default_cache_batch_latents call to pass multi_resolution=True
src = src.replace(
    "        self._default_cache_batch_latents(encode_by_vae, vae_device, vae_dtype, image_infos, flip_aug, alpha_mask, random_crop)",
    "        self._default_cache_batch_latents(encode_by_vae, vae_device, vae_dtype, image_infos, flip_aug, alpha_mask, random_crop, multi_resolution=True)",
)

with open(path, "w") as f:
    f.write(src)

print("Synthesis complete: strategy_sd.py updated with multi-resolution support")
PYEOF

# Verify syntax
RUN python3 -c "import ast; ast.parse(open('/workspace/sd-scripts/library/strategy_sd.py').read()); print('strategy_sd.py: syntax OK')"

# Set PYTHONPATH
ENV PYTHONPATH="/workspace/sd-scripts"

# Configure git for agent use
RUN git config --global user.email "agent@test.com" && \
    git config --global user.name "Test Agent"

# Pre-install Claude Code CLI (standalone binary, no Node.js needed)
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:$PATH"


WORKDIR /workspace/sd-scripts
