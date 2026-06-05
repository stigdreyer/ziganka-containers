# Home Assistant SSO via Authelia (OIDC)

Home Assistant on the HALPI2 uses `routing.auth.mode: none` — it is **not**
gated by Traefik forward-auth. HA already requires its own login on every door
(native `:8123` and the proxied per-app HTTPS port), so a forward-auth layer
would be redundant, wouldn't cover `:8123`, and is known to break the Companion
app, WebSocket, long-lived tokens, and `/api/`.

For real single sign-on (one Authelia identity instead of separate HA
passwords), add the
**[`hass-oidc-auth`](https://github.com/christiaangoossens/hass-oidc-auth)**
HACS integration as an OIDC client against Authelia.

## What the package automates for you

`ziganka-homeassistant-container`'s `prestart.sh` registers the Authelia side
automatically on every (re)start — so this is **portable across boats** and you
never hand-manage secrets or redirect URIs:

- Generates a client secret once at
  `/var/lib/container-apps/ziganka-homeassistant-container/data/oidc-secret`.
- Writes `/etc/halos/oidc-clients.d/homeassistant.yml` (HaLOS merges + hashes it
  into Authelia), with the redirect URI derived from `HALOS_DOMAIN` and HA's
  per-app port from `/etc/halos/port-registry` — e.g.
  `https://halos.local:4433/auth/oidc/callback`.
- Seeds `oidc_client_secret` into HA's `secrets.yaml` so the config block below
  can use `!secret oidc_client_secret` with nothing to copy by hand.

The container's compose also maps `${HALOS_DOMAIN}` to `127.0.0.1`
(`extra_hosts`) so HA's **server-side** calls to `https://halos.local/sso/...`
resolve — the container's resolver does not do mDNS, and without this the OIDC
callback fails with a 500 (`Cannot connect to host ... Domain name not found`).

## What you still do by hand (two steps)

A host prestart can't reach into HA's runtime, so these stay manual:

### 1. Install the HACS integration

In HA → HACS → custom repository
`https://github.com/christiaangoossens/hass-oidc-auth` (type: Integration) →
install **OpenID Connect (OIDC) Authentication**, then restart HA.

### 2. Add the `auth_oidc:` block to `configuration.yaml`

```yaml
auth_oidc:
  client_id: homeassistant
  client_secret: !secret oidc_client_secret   # seeded by prestart.sh
  discovery_url: "https://halos.local/sso/.well-known/openid-configuration"
  display_name: "HaLOS SSO"
  features:
    automatic_user_linking: true   # link to an existing HA user by username
    force_https: true              # build https callback behind the TLS proxy
  network:
    tls_verify: false              # HaLOS uses a self-signed CA
  roles:
    admin: "admins"                # Authelia group → HA admin
```

This is a **confidential** client (matches the proven HaLOS pattern used by
Signal K / Homarr; HaLOS hashes the secret into Authelia). Restart HA after
adding it.

## Verify

- Open HA **through the HTTPS door** — the dashboard card / `https://halos.local/homeassistant/`
  (which 302-redirects to the per-app port), **not** `http://halos.local:8123`.
  The callback is registered on the HTTPS per-app port, so the flow must start
  there.
- Choose **"HaLOS SSO"** on the login screen → authenticate at Authelia → land
  back in HA. A user in the Authelia `admins` group gets HA admin.
- HA's local accounts still work as a fallback.

Confirm the Authelia client merged:

```bash
sudo sed -n '/client_id: homeassistant/,/token_endpoint_auth_method/p' \
  /var/lib/container-apps/halos-core-containers/data/authelia/oidc-clients.yml
```

## Troubleshooting

- **500 on callback, log shows `Domain name not found` for `halos.local`** —
  the `extra_hosts` mapping is missing/not applied. Confirm the container
  resolves it: `sudo docker exec homeassistant getent hosts halos.local`
  (should be `127.0.0.1`). Reinstall/upgrade the package or restart the service.
- **`redirect_uri` rejected by Authelia** — the URI HA sent doesn't match the
  registered one. The error page shows the URI HA used; make sure it equals the
  `redirect_uris` entry in `/etc/halos/oidc-clients.d/homeassistant.yml`
  (host + per-app port + `/auth/oidc/callback`). Adjust the snippet and
  `sudo systemctl restart halos-core-containers.service`.
- **TLS errors fetching discovery** — ensure `network.tls_verify: false` (HaLOS
  CA is self-signed), or mount the CA and set `network.tls_ca_path`.
- **Logged in but no admin** — confirm your Authelia user is in the `admins`
  group (`users_database.yml`) and `roles.admin` matches that group name.
- **Don't** put Traefik forward-auth in front of HA to "double up" — keep
  `routing.auth.mode: none`.
