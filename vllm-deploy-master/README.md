# Qwen3.6 35B A3B FP8 — vLLM deployment on a dedicated server

Idempotent Ansible playbook that installs and configures an **OpenAI-compatible** endpoint
serving **Qwen3.6 35B A3B FP8** via **vLLM**, following production best practices and
performance optimisations. Designed to be the inference server for the NSN architecture
(Hermes points to it as its LLM backend).

## What the playbook does

1. System tuning (`tuned` throughput-performance profile).
2. NVIDIA driver (optional) + GPU persistence mode.
3. Docker Engine + NVIDIA Container Toolkit (GPU runtime).
4. `systemd` service running the **vLLM** container with optimised flags.
5. Model weight pre-download (avoids a very long first startup).
6. `ufw` firewall (SSH + API restricted by CIDR).
7. `/health` and `/v1/models` healthchecks.

## Requirements

- Ubuntu 22.04/24.04/26.04 server with NVIDIA GPU.
- SSH access + sudo.
- Control node: `ansible` (ansible-core is enough, no external collections required).

## Usage

```bash
cp vars.example.yml vars.yml          # fill in vllm_api_key (and hf_token if needed)
ansible-playbook -i inventory.ini deploy-gemma-vllm.yml -e @vars.yml --ask-become-pass
```

To encrypt secrets: `ansible-vault encrypt vars.yml` then add `--ask-vault-pass`.

## Launch flags — detailed reference

### Model and quantization

**`--model Qwen/Qwen3.6-35B-A3B-FP8`**
Hugging Face repository of the checkpoint to load. This is a Mixture-of-Experts model with
35B total parameters but only ~3.6B active per token (A3B). The `-FP8` suffix means the
weights are already stored in FP8 format on the Hub — no on-the-fly quantization is needed,
which cuts download size roughly in half compared to a bf16 checkpoint and eliminates the
quantization step at startup.

**`--served-model-name qwen3.6-35b-a3b`**
The model name clients must use in the `"model"` field of OpenAI API requests. Decoupled
from the HF repo path so you can rename without changing the client.

**`--kv-cache-dtype fp8`**
Stores the KV cache in FP8 instead of the default bf16. Halves the memory footprint of
the attention cache, which directly doubles either the number of concurrent sequences or the
achievable context length for a given GPU memory budget.

**`--gpu-memory-utilization 0.90`**
Fraction of total GPU VRAM that vLLM is allowed to allocate (weights + KV cache combined).
Leaving 10% free avoids OOM spikes from CUDA memory fragmentation and system overhead.
Lower to 0.85 if you observe OOM errors under heavy load.

---

### Context and concurrency

**`--max-model-len 131072`**
Maximum sequence length (prompt + generated tokens) in tokens. Set to the model's native
128K context. Reducing this is the first lever to pull if you run out of KV cache memory —
every saved token frees proportional VRAM for more concurrent sequences.

**`--max-num-seqs 32`**
Hard cap on the number of sequences that can be in flight simultaneously (prefill + decode).
Caps memory pressure and guarantees bounded latency under burst traffic. Tune upward if the
GPU has headroom; downward if tail latency is too high.

---

### Multimodal / vision

**`--language-model-only`**
Instructs vLLM not to load the vision encoder. Qwen3.6 is a text-only MoE model; this flag
makes the intent explicit and prevents vLLM from allocating memory for visual components
that will never be used.

**`--limit-mm-per-prompt '{"image": 0}'`**
Belt-and-suspenders guard: even if a client sends an image in a request, vLLM will reject it
with a clear error rather than silently failing or wasting compute.

---

### Tool calling and reasoning

**`--enable-auto-tool-choice`**
Allows the model to decide on its own whether to call a tool, without the client having to
force `tool_choice: "auto"` on every request. Required for agentic workflows.

**`--tool-call-parser qwen3_xml`**
Selects the parser that extracts structured tool calls from the model's raw output. Qwen3
emits tool calls wrapped in XML tags; this parser understands that format and converts them
to the standard OpenAI `tool_calls` JSON structure.

**`--reasoning-parser qwen3`**
Extracts the content of `<think>…</think>` blocks from the model's output and exposes it
in the API response under a dedicated field, separate from the final answer. Lets clients
display or log the chain-of-thought without post-processing the raw text.

**`--default-chat-template-kwargs '{"enable_thinking": true, "thinking_budget": 1024}'`**
Passed to the Jinja2 chat template at render time:
- `enable_thinking: true` — injects the system-level instruction that activates the
  model's internal reasoning mode (`<think>` blocks).
- `thinking_budget: 1024` — soft cap on reasoning tokens per turn. Balances response
  quality against latency; increase for complex multi-step tasks, decrease for simple Q&A.

---

### Speculative decoding

**`--speculative-config '{"method": "mtp", "num_speculative_tokens": 2}'`**
Enables Multi-Token Prediction (MTP) speculative decoding. The model's internal draft head
proposes 2 tokens ahead; the main model verifies them in a single forward pass. When the
draft is correct (which happens most of the time on repetitive or predictable text), you get
2 tokens for roughly the cost of 1, increasing effective throughput by 20–40% with no
quality degradation. No separate draft model is required — the draft head is part of the
Qwen3.6 checkpoint itself.

---

### Scheduling

**`--enable-chunked-prefill`**
Splits long prompt prefills into fixed-size chunks interleaved with decode steps. Without
this, a single long prompt monopolises the GPU during its entire prefill, stalling all
other active sequences. Chunked prefill keeps tail latency (P99) stable under mixed
short/long prompt traffic.

**`--async-scheduling`**
Decouples the scheduler loop from the forward pass execution. The scheduler can prepare the
next batch while the GPU is still processing the current one, reducing the CPU-side
scheduling overhead that would otherwise add dead time between batches.

---

### Mamba / SSM hybrid layers

Qwen3.6 35B A3B is a hybrid architecture: most layers are standard Transformer attention,
but a subset are SSM (State Space Model / Mamba-style) layers. These flags configure their
caching behaviour.

**`--mamba-cache-dtype float16`**
Data type for the recurrent SSM state cache. `float16` is a good balance between precision
and memory. Using `bfloat16` is also valid but slightly less precise for the SSM recurrence.

**`--mamba-ssm-cache-dtype float16`**
Data type specifically for the SSM convolution state (the 1-D conv component of Mamba
layers), separate from the recurrent state above.

**`--enable-mamba-cache-stochastic-rounding`**
When accumulating SSM states in float16, small values can underflow to zero. Stochastic
rounding adds controlled noise before truncating, which statistically preserves gradient
signal and prevents this underflow from compounding across layers. Improves quality at long
contexts where SSM states accumulate many small updates.

**`--mamba-cache-mode align`**
Controls how the Mamba state cache is allocated across the batch. `align` mode aligns cache
slots to sequence boundaries, which avoids partial-sequence cache conflicts when sequences
have different lengths and is required for correct behaviour with chunked prefill.

---

### Prefix caching and backend

**`--enable-prefix-caching`**
Caches the KV tensors of repeated prompt prefixes across requests. Critical for agentic
workloads (Hermes) where every request shares the same long system prompt and tool
definitions — the first request pays the prefill cost, all subsequent ones skip it entirely.

**`--gdn-prefill-backend triton`**
Selects the Triton kernel implementation for the GDN (Gated Dense Network) prefill
computation used in the SSM layers. The Triton backend is more performant than the fallback
PyTorch implementation on NVIDIA Ada/Hopper GPUs and is required for correct chunked-prefill
support with Mamba layers.

---

### Networking and security

**`--host 0.0.0.0 --port 8000`**
Binds the HTTP server on all interfaces inside the container. The actual external exposure
is controlled by the Docker `-p` flag (`vllm_bind_host:8000:8000`), so set
`vllm_bind_host: "127.0.0.1"` in vars.yml to restrict access to localhost even though the
container itself listens on all interfaces.

**`--trust-remote-code`**
Allows vLLM to execute the custom Python code shipped in the Qwen3 HF repository (tokenizer
configuration, architecture registration). Required for any model that uses non-standard
components not yet merged into the vLLM / Transformers core.

## Verify

```bash
# On the server (loopback):
curl -H "Authorization: Bearer <vllm_api_key>" http://127.0.0.1:8000/v1/models

# Generation test:
curl http://127.0.0.1:8000/v1/chat/completions \
  -H "Authorization: Bearer <vllm_api_key>" -H "Content-Type: application/json" \
  -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"Hello!"}]}'

# Logs / metrics:
journalctl -u gemma-vllm -f
curl http://127.0.0.1:8000/metrics      # Prometheus metrics (requests_waiting, kv_cache_usage...)
```

## Connect Hermes to this endpoint

```
base_url = http://<server-private-ip>:8000/v1
api_key  = <vllm_api_key>
model    = qwen3.6-35b-a3b
context_length = 131072
```

## Security notes

- The API key is required on all `/v1` routes.
- Secrets are stored in `/etc/gemma-vllm/gemma-vllm.env` (mode 0600) and passed to the
  container via `--env-file` (never on the command line).
- Set `disable_request_logging: true` to avoid logging request content (GDPR).
- `api_allowed_cidrs` restricts firewall access when `vllm_bind_host: "0.0.0.0"`.

## Operational notes

- **Systemd vs Docker restart**: the unit uses `Restart=always` + `--rm`; do **not** pass
  `--restart` to Docker — having both active causes conflicts.
- **Multi-GPU**: set `tensor_parallel_size: N` in vars.yml; the playbook adds
  `--tensor-parallel-size N` automatically.
- **Extra flags**: use `extra_vllm_args` for any additional vLLM arguments.
- **NVIDIA driver**: if `install_nvidia_driver: true` triggers a driver install, the playbook
  will stop and ask you to reboot before re-running.
