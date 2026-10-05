"""Self-hosted model serving for the agent seat (``vllm`` backend).

Serving an open-weights model on the cluster is split in two so the benchmark
treats the server like any other API:

* a long-lived Slurm *serve* job runs ``vllm serve`` and writes a handoff file
  (``endpoint.json``) once the server answers ``/v1/models``;
* trial jobs read the handoff, install a model-pinned ``/vllm/`` reverse route on
  the egress relay and point opencode at ``http://127.0.0.1:3128/vllm/v1``. The
  sandbox never learns the server address or its API key.

This package is **stdlib only**: :mod:`serving.vllm_server` runs inside the
serving conda env, which has vLLM but none of the benchmark's dependencies.
"""
