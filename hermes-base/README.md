# hermes-base

Base Docker image for **Hermes** deployments at NorthStar Network.

Combines:
- **Hermes WebUI** (`ghcr.io/nesquena/hermes-webui`) — multi-agent web interface
- **Hermes Agent** (`nousresearch/hermes-agent`) — LLM daemon + gateway
- **Custom skills** — extensible `skills/` directory baked into the image

Runtime configuration is fully driven by environment variables (`.env`); no rebuild needed to swap models or endpoints.

---

## Quick start

```sh
cp .env.example .env
# Fill in your values (see Environment variables below)
docker compose up -d
```

The WebUI is available at `http://<APP_FQDN>` via Traefik, or directly on port `8787`.

---

## Architecture

```
┌──────────────────────────────────────────┐
│  hermes-webui  :8787                     │  ← web interface
│                                          │
│  hermes-gateway :8642  (Python daemon)   │  ← LLM engine / MCP hub
└──────────────────────────────────────────┘
          │ Traefik (external network)
          ▼
     APP_FQDN (HTTP/HTTPS)
```

`entrypoint.sh` runs at container start:
1. Writes `config.yaml` from the baked-in template (`envsubst`)
2. Symlinks official Hermes skills on first boot
3. Copies custom project skills (`/etc/hermes/skills → ~/.hermes/skills`) on every start
4. Launches the gateway daemon in the background as `hermeswebui`
5. Hands off to the official WebUI init script

---

## Environment variables

Copy `.env.example` to `.env` and fill in:

| Variable | Description |
|----------|-------------|
| `PROJECT_NAME` | Project name (container prefix, Traefik label) |
| `APP_FQDN` | Access domain (e.g. `hermes-tech.internal`) |
| `TRAEFIK_NETWORK` | External Traefik network name (default: `traefik`) |
| `MODEL_BASE_URL` | OpenAI-compatible endpoint URL (e.g. `http://host:8000/v1`) |
| `MODEL_NAME` | Model name as served by the backend |
| `MODEL_API_KEY` | Backend API key (`no-key` for unauthenticated internal endpoints) |
| `CONTEXT_LENGTH` | Context window size (Hermes hard-minimum: 64 000) |
| `MAX_TOKENS` | Max output tokens (recommended: ≤ `CONTEXT_LENGTH / 2`) |
| `HERMES_WEBUI_PASSWORD` | WebUI access password — **required for any public-facing deployment** |
| `UID` / `GID` | Host user/group ID for volume ownership (`id -u` / `id -g`) |

---

## Model configuration

The model is configured in two places that work together:

**`.env`** holds the runtime values:

```dotenv
MODEL_BASE_URL=http://host:8000/v1   # OpenAI-compatible endpoint
MODEL_NAME=my-custom-model           # model name as the backend expects it
MODEL_API_KEY=my-token               # use "no-key" for unauthenticated endpoints
CONTEXT_LENGTH=64000                 # full context window (hard-minimum: 64 000)
MAX_TOKENS=32000                     # max tokens the model generates per turn
```

**`config.yaml`** consumes them via `envsubst` at container start:

```yaml
model:
  default: "${MODEL_NAME}"
  provider: "custom"          # tells Hermes to use an OpenAI-compatible endpoint
  base_url: "${MODEL_BASE_URL}"
  api_key: "${MODEL_API_KEY}"
  context_length: ${CONTEXT_LENGTH}
  max_tokens: ${MAX_TOKENS}
```

`config.yaml` is overwritten from this template on every `docker compose up`, so changing a value in `.env` and restarting the container is enough — no rebuild needed.

**`CONTEXT_LENGTH` vs `MAX_TOKENS`:** `CONTEXT_LENGTH` is the total window the model can see (input + output). `MAX_TOKENS` caps the output portion alone. A safe default is `MAX_TOKENS = CONTEXT_LENGTH / 2`.

---

## Custom skills

Drop skill directories into `skills/`. They are copied into `~/.hermes/skills/` on every container start, so updates are picked up with a simple `docker compose restart` — no rebuild required.

---

## Network prerequisites

- External Docker network **Traefik** must exist (`TRAEFIK_NETWORK`, default: `traefik`)
- Port `8642` is exposed on the host for the gateway API (internal use)
