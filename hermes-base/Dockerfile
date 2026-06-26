# ─────────────────────────────────────────────────────────────────────────────
# hermes-tech — Production image (no Ollama)
#
# Multi-stage build:
#   Stage 1 (agent-src): extract /opt/hermes from the official agent image
#   Stage 2 (final):     WebUI image with agent source baked in + custom entrypoint
#
# Runtime config is injected via environment variables (see .env.example).
# The entrypoint seeds config.yaml from a template before starting the WebUI.
# ─────────────────────────────────────────────────────────────────────────────

# Stage 1 — pull agent source only
FROM nousresearch/hermes-agent:latest AS agent-src

# Stage 2 — production WebUI
FROM ghcr.io/nesquena/hermes-webui:latest

# Bake the agent source directly into the image (no volume dependency at runtime)
COPY --from=agent-src /opt/hermes /opt/hermes-agent

# Make `hermes` available system-wide
RUN ln -s /opt/hermes-agent/hermes /usr/local/bin/hermes

# Node.js — required to run npx-based MCP servers (GitLab, Sentry, DataForSEO…)
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm gettext-base \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Packages must be installed in TWO places because two different Python runtimes
# are active in this image:
#   1. /opt/hermes-agent/.venv  — Python 3.13 venv used by the gateway daemon
#      and the agent's execute_code sandbox (invoked via the venv's python directly)
#   2. /usr/local/bin/python3   — Python 3.12 system interpreter used by the
#      `hermes` CLI shebang (#!/usr/bin/env python3). Installing only in the venv
#      leaves the CLI unable to import modules like yaml, pydantic, etc.
# Bootstrap pip into the venv first (the base image ships without it):
# pandas          — data manipulation and analysis (DataFrames, CSV, JSON…)
# numpy           — numerical computing and array operations
# requests        — HTTP client for calling external APIs
# matplotlib      — plotting and chart generation
# scipy           — scientific computing (stats, signal processing…)
# beautifulsoup4  — HTML/XML parsing and web scraping
# openpyxl        — read/write modern Excel files (.xlsx)
# xlrd            — read legacy Excel files (.xls)
# python-dotenv   — load environment variables from .env files
# pyyaml          — YAML parsing and serialization
# pydantic        — data validation and settings management
# packaging       — version parsing and dependency specifiers
# openai          — OpenAI-compatible API client
# fire            — CLI generation from Python objects
# rich            — terminal formatting and pretty-printing
# tenacity        — retry logic with exponential backoff
# jinja2          — templating engine
# prompt_toolkit  — interactive CLI input and REPL support
# croniter        — cron expression parsing and scheduling
# psutil          — system/process monitoring
# pathspec        — gitignore-style path matching
# fastapi         — lightweight async web framework
# pillow          — image processing and manipulation
RUN curl -sS https://bootstrap.pypa.io/get-pip.py | /opt/hermes-agent/.venv/bin/python \
    && /opt/hermes-agent/.venv/bin/pip install --no-cache-dir \
    openai \
    python-dotenv \
    fire \
    "httpx[socks]" \
    rich \
    tenacity \
    pyyaml \
    "ruamel.yaml" \
    requests \
    jinja2 \
    pydantic \
    prompt_toolkit \
    croniter \
    packaging \
    Markdown \
    "PyJWT[crypto]" \
    urllib3 \
    psutil \
    pathspec \
    fastapi \
    "uvicorn[standard]" \
    ptyprocess \
    Pillow \
    && python3 -m pip install --no-cache-dir \
    openai \
    python-dotenv \
    fire \
    "httpx[socks]" \
    rich \
    tenacity \
    pyyaml \
    "ruamel.yaml" \
    requests \
    jinja2 \
    pydantic \
    prompt_toolkit \
    croniter \
    packaging \
    Markdown \
    "PyJWT[crypto]" \
    urllib3 \
    psutil \
    pathspec \
    fastapi \
    "uvicorn[standard]" \
    ptyprocess \
    Pillow


# Config template + entrypoint
COPY config.yaml /etc/hermes/config.yaml
COPY skills /etc/hermes/skills
COPY entrypoint.sh   /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8787

ENTRYPOINT ["/entrypoint.sh"]
