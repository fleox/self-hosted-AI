#!/bin/sh
set -e

HERMES_HOME="${HERMES_HOME:-/home/hermeswebui/.hermes}"
CONFIG_DEST="${HERMES_HOME}/config.yaml"
AGENT_LINK="${HERMES_HOME}/hermes-agent"
HERMES_API_KEY="${HERMES_API_KEY:-local-gateway-noop}"

# ── 1. Ensure HERMES_HOME exists ─────────────────────────────────────────────
mkdir -p "${HERMES_HOME}"

# ── 2. Seed agent source (symlink into HERMES_HOME so WebUI finds it) ────────
if [ ! -e "${AGENT_LINK}" ]; then
    ln -s /opt/hermes-agent "${AGENT_LINK}"
fi

# ── 3. Always overwrite config.yaml from the baked-in file ───────────────────
# Always overwriting means a `docker compose up` picks up config changes
# without needing to wipe the volume.
envsubst < /etc/hermes/config.yaml > "${CONFIG_DEST}"
echo "[hermes-tech] config.yaml written to ${CONFIG_DEST}"

# ── 4. Seed skills ───────────────────────────────────────────────────────────
SKILLS_DIR="${HERMES_HOME}/skills"
AGENT_SKILLS="/opt/hermes-agent/skills"
mkdir -p "${SKILLS_DIR}"

# 4a. Seed official skills from agent source (only on first boot)
if [ -d "${AGENT_SKILLS}" ] && [ -z "$(ls -A "${SKILLS_DIR}")" ]; then
    for skill_dir in "${AGENT_SKILLS}"/*/; do
        skill_name="$(basename "${skill_dir}")"
        ln -s "${skill_dir}" "${SKILLS_DIR}/${skill_name}"
    done
    echo "[hermes-tech] skills seeded from ${AGENT_SKILLS}"
fi

# 4b. Copy custom project skills (always, so repo changes are picked up on restart)
if [ -d /etc/hermes/skills ]; then
    cp -r /etc/hermes/skills/. "${SKILLS_DIR}/"
    echo "[hermes-tech] custom skills copied from /etc/hermes/skills"
fi

# ── 5. Schedule the gateway daemon (deferred, runs as hermeswebui) ───────────
# The gateway MUST NOT run as root:
#   - it would litter ~/.hermes with root-owned files (state.db, gateway.lock,
#     cron/, logs/ ...) that the WebUI runtime user can no longer write to
#     after a restart — this was the original permission bug.
# It also must not start before hermeswebui_init.bash has finished its root
# phase, because that script runs `usermod -u` on the hermeswebui user and
# usermod fails if any process already runs under that UID.
#
# The init script writes an env snapshot file right before dropping
# privileges via `su`. We poll for that file (including its documented
# fallback locations) as a "root phase done" signal, then start the gateway
# as the runtime user. By that point the init script has already chowned
# /home/hermeswebui back to the correct UID/GID, repairing any leftover
# root-owned files from previous runs.

# Remove stale markers: `docker restart` keeps the container filesystem,
# so a marker from the previous run must not trigger an early start.
rm -f /tmp/hermeswebui_root_env.txt \
      /tmp/hermeswebui_init/hermeswebui_root_env.txt \
      /app/.hermeswebui_root_env 2>/dev/null || true

(
    # Wait for the init script's root phase to complete
    while :; do
        for marker in /tmp/hermeswebui_root_env.txt \
                      /tmp/hermeswebui_init/hermeswebui_root_env.txt \
                      /app/.hermeswebui_root_env; do
            if [ -f "${marker}" ]; then
                break 2
            fi
        done
        sleep 1
    done
    # Small grace period so the `su` re-exec in the init script has happened
    sleep 2

    echo "[hermes-tech] starting gateway daemon as hermeswebui"
    cd /opt/hermes-agent
    exec su -s /bin/sh hermeswebui -c "
        export HOME=/home/hermeswebui
        export HERMES_HOME='${HERMES_HOME}'
        export PYTHONPATH=/opt/hermes-agent
        export API_SERVER_ENABLED=true
        export API_SERVER_HOST=0.0.0.0
        export API_SERVER_KEY=${HERMES_API_KEY}
        exec /opt/hermes-agent/.venv/bin/python -m gateway.run
    "
) &

# Exported for the WebUI process so it can reach the local gateway
export HERMES_API_URL=http://127.0.0.1:8642

# ── 6. Hand off to the official WebUI startup ────────────────────────────────
# No `chown -R` here: hermeswebui_init.bash already performs a smarter chown
# in its root phase (it prunes read-only mounts and .git directories), and
# doing it before the UID/GID alignment would be wasted work anyway.
exec /hermeswebui_init.bash "$@"
