# self-hosted-AI

Reference sources and production-tested configurations for the self-hosted AI
stack described in the companion blog post. Everything in this repository is the
exact code we run — battle-tested defaults, tuned launch flags, and the wiring
that makes the pieces talk to each other.

The stack is split in two layers, each in its own directory:

```
┌─────────────────────────────────────────────┐
│  hermes-base/         (web UI + agent)       │
│  ─────────────                               │
│  Multi-agent web interface that talks to     │
│  any OpenAI-compatible endpoint.             │
└─────────────────────────────────────────────┘
                     │
                     │  HTTP (OpenAI-compatible /v1)
                     ▼
┌─────────────────────────────────────────────┐
│  vllm-deploy-master/  (inference server)     │
│  ────────────────────                        │
│  Ansible playbook deploying Qwen3.6 35B      │
│  A3B FP8 on vLLM with optimised flags.       │
└─────────────────────────────────────────────┘
```

---

## What's in here

### [`hermes-base/`](hermes-base/) — Hermes WebUI + Agent (Docker)

A Docker image bundling the Hermes WebUI and the Hermes agent daemon, fully
configurable through environment variables. Drops behind Traefik, points at any
OpenAI-compatible endpoint (the vLLM server below, or any third-party provider),
and ships a `skills/` directory for custom agent extensions.

See [`hermes-base/README.md`](hermes-base/README.md) for the full setup,
environment variables, and architecture details.

### [`vllm-deploy-master/`](vllm-deploy-master/) — vLLM inference server (Ansible)

An idempotent Ansible playbook that turns a fresh Ubuntu + NVIDIA GPU box into
an OpenAI-compatible inference endpoint serving **Qwen3.6 35B A3B FP8** through
vLLM. Every launch flag is documented and chosen to balance throughput, latency,
and VRAM footprint on a single dedicated server.

Highlights of the configuration:

- **FP8 weights + FP8 KV cache** — half the memory of a bf16 run.
- **MTP speculative decoding** — 20–40% extra throughput at no quality cost.
- **Prefix caching + chunked prefill** — stable P99 latency under agentic
  workloads where every request shares a long system prompt.
- **Mamba/SSM tuning** — correct caching flags for Qwen3's hybrid architecture.
- **Tool calling + reasoning parsers** — native `<think>` and XML tool-call
  support exposed through the OpenAI API.

See [`vllm-deploy-master/README.md`](vllm-deploy-master/README.md) for the full
reference of every flag and why we set it.

---

## Reference documents

Two PDFs ship alongside the code as primary-source references:

- [`Hermes-configuration-field-report.pdf`](Hermes-configuration-field-report.pdf)
  — field notes from the Hermes deployment.
- [`Hybrid-memory-KVcache-DeltaNet.pdf`](Hybrid-memory-KVcache-DeltaNet.pdf)
  — background on the hybrid attention / SSM memory architecture that drives
  some of the vLLM Mamba-cache flags.

---

## Quick start

A typical end-to-end bring-up:

1. **Provision the GPU server** with the vLLM playbook.
   ```bash
   cd vllm-deploy-master
   cp vars.example.yml vars.yml          # fill in vllm_api_key (and hf_token if needed)
   ansible-playbook -i inventory.ini deploy-gemma-vllm.yml -e @vars.yml --ask-become-pass
   ```

2. **Boot the Hermes WebUI** on any Docker host and point it at the vLLM endpoint.
   ```bash
   cd hermes-base
   cp .env.example .env                  # set MODEL_BASE_URL=http://<gpu-host>:8000/v1
   docker compose up -d
   ```

3. **Open the WebUI** at `http://<APP_FQDN>` (or `:8787` directly) and start
   chatting against your self-hosted model.

---

## Secrets

`vllm-deploy-master/vars.yml` is gitignored — it holds the Hugging Face token and
the vLLM API key. Use `vars.example.yml` as the template, and consider
`ansible-vault encrypt vars.yml` for shared environments.
