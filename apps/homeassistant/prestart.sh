#!/bin/bash
# Home Assistant prestart for Ziganka.
#
# Two jobs:
#   1. Parity with the container-packaging-tools default: write runtime.env
#      (HOSTNAME / HALOS_DOMAIN / HOMARR_URL) used for compose substitution
#      and the Homarr dashboard label.
#   2. Register an Authelia OIDC client for SSO (hass-oidc-auth), so the
#      HaLOS/Authelia side is zero-touch and portable across boats — the
#      secret, the client snippet, and the per-device redirect URI are all
#      generated here, the same way Signal K self-registers.
#
# What this CANNOT do (host prestart can't reach into HA's runtime), so it
# stays a documented manual step in docs/homeassistant-oidc.md:
#   - installing the `hass-oidc-auth` HACS integration
#   - adding the `auth_oidc:` block to configuration.yaml
# The secret seeded into secrets.yaml below lets that block reference
# `!secret oidc_client_secret` with no manual secret juggling.
set -e

PKG=ziganka-homeassistant-container
DATA_ROOT="${CONTAINER_DATA_ROOT:-/var/lib/container-apps/${PKG}}"
HA_CONFIG="${DATA_ROOT}/config"

# --- runtime.env (parity with the generated default) ---
RUNTIME_ENV="/run/container-apps/${PKG}/runtime.env"
mkdir -p "$(dirname "${RUNTIME_ENV}")"

set -a
[ -f "/etc/container-apps/${PKG}/env.defaults" ] && . "/etc/container-apps/${PKG}/env.defaults"
[ -f "/etc/container-apps/${PKG}/env" ] && . "/etc/container-apps/${PKG}/env"
set +a

HOSTNAME="$(hostname -s)"
HALOS_DOMAIN="${HALOS_DOMAIN:-${HOSTNAME}.local}"
{
    echo "HOSTNAME=${HOSTNAME}"
    echo "HALOS_DOMAIN=${HALOS_DOMAIN}"
    echo "HOMARR_URL=http://${HALOS_DOMAIN}:8123"
} > "${RUNTIME_ENV}"

# --- Authelia OIDC client registration (SSO) ---
# Generate the client secret once; HaLOS hashes client_secret_file into
# Authelia's config and keeps the plaintext only in the file below.
OIDC_SECRET_FILE="${DATA_ROOT}/oidc-secret"
if [ ! -f "${OIDC_SECRET_FILE}" ]; then
    openssl rand -hex 32 > "${OIDC_SECRET_FILE}"
    chmod 600 "${OIDC_SECRET_FILE}"
fi

# HA's per-app HTTPS port (assigned by configure-container-routing, which runs
# before this script). HA cannot run under a subpath, so the OIDC callback uses
# the per-app port URL — and HA builds exactly this redirect_uri when reached
# over the proxied HTTPS port (with hass-oidc-auth's force_https).
HA_PORT=4433
PORT_REGISTRY="/etc/halos/port-registry"
if [ -f "${PORT_REGISTRY}" ]; then
    P=$(grep "^homeassistant=" "${PORT_REGISTRY}" 2>/dev/null | cut -d= -f2)
    [ -n "${P}" ] && HA_PORT="${P}"
fi

# Always (re)write the client snippet so the redirect URI tracks domain/port
# changes across upgrades. HaLOS merges all snippets into Authelia's clients.
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
mkdir -p "${OIDC_CLIENTS_DIR}"
cat > "${OIDC_CLIENTS_DIR}/homeassistant.yml" << EOF
# Home Assistant OIDC client for hass-oidc-auth
# Installed by ${PKG} prestart.sh — see docs/homeassistant-oidc.md
client_id: homeassistant
client_name: Home Assistant
client_secret_file: ${OIDC_SECRET_FILE}
redirect_uris:
  - 'https://${HALOS_DOMAIN}:${HA_PORT}/auth/oidc/callback'
scopes: [openid, profile, email, groups]
consent_mode: implicit
token_endpoint_auth_method: client_secret_post
EOF

# Seed the secret into HA's secrets.yaml (idempotent) so the documented
# auth_oidc: block can reference `!secret oidc_client_secret` directly.
if [ -d "${HA_CONFIG}" ]; then
    SECRETS="${HA_CONFIG}/secrets.yaml"
    touch "${SECRETS}"
    if ! grep -q '^oidc_client_secret:' "${SECRETS}" 2>/dev/null; then
        printf 'oidc_client_secret: "%s"\n' "$(cat "${OIDC_SECRET_FILE}")" >> "${SECRETS}"
    fi
fi
