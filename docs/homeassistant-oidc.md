# Home Assistant SSO via Authelia (OIDC)

Home Assistant on the HALPI2 uses `routing.auth.mode: none` — it is **not**
gated by Traefik forward-auth. HA already requires its own login on every door
(native `:8123` and the proxied `:4433`), so a forward-auth layer would be
redundant, wouldn't cover `:8123`, and is known to break the Companion app,
WebSocket, long-lived tokens, and `/api/`.

To get real single sign-on (one Authelia identity instead of separate HA
passwords), add the **[`hass-oidc-auth`](https://github.com/christiaangoossens/hass-oidc-auth)**
HACS integration as an OIDC client against Authelia. This is an **outbound**
OIDC flow from HA, so it works fine under host networking — the callback
resolves through the `/homeassistant/` → `:4433` path redirect that HaLOS
generates from the package's `routing.d` declaration.

This is an app-config/HACS change on the device, **not** a `.deb` change — it
lives here in `docs/`, not in `apps/homeassistant/`.

## Prerequisites

- HACS installed in Home Assistant.
- Authelia running on HaLOS (it is, by default).
- The HALPI2 domain, referred to below as `${HALOS_DOMAIN}` (e.g. `halos.local`).

## 1. Register the Authelia OIDC client

HaLOS merges per-app client snippets from `/etc/halos/oidc-clients.d/*.yml`
into Authelia's config (the same mechanism Signal K and Homarr use). Create
`/etc/halos/oidc-clients.d/homeassistant.yml` on the HALPI2:

```yaml
# Home Assistant OIDC client for Authelia SSO
client_id: homeassistant
client_name: Home Assistant
# Generate the secret once on the device:
#   openssl rand -hex 32 | sudo tee /var/lib/container-apps/ziganka-homeassistant-container/data/oidc-secret
#   sudo chmod 600 /var/lib/container-apps/ziganka-homeassistant-container/data/oidc-secret
client_secret_file: /var/lib/container-apps/ziganka-homeassistant-container/data/oidc-secret
redirect_uris:
  # hass-oidc-auth's callback. The /homeassistant/ path 302-redirects to the
  # per-app TLS port (:4433), so the callback reaches HA.
  - 'https://${HALOS_DOMAIN}/homeassistant/auth/oidc/callback'
scopes: [openid, profile, email, groups]
consent_mode: implicit
token_endpoint_auth_method: client_secret_post
```

Generate the secret and apply (Authelia's prestart re-merges snippets on
restart of the HaLOS core stack):

```bash
sudo openssl rand -hex 32 \
  | sudo tee /var/lib/container-apps/ziganka-homeassistant-container/data/oidc-secret >/dev/null
sudo chmod 600 /var/lib/container-apps/ziganka-homeassistant-container/data/oidc-secret
# Restart the core stack so Authelia picks up the new client.
sudo systemctl restart halos-core-containers-container
```

## 2. Install and configure hass-oidc-auth

1. In HA → HACS → add the custom repository
   `https://github.com/christiaangoossens/hass-oidc-auth` (category:
   Integration), then install **OpenID Connect (OIDC) Authentication**.
2. Add the integration's config to `configuration.yaml` (see the project's
   README for the current schema). Roughly:

   ```yaml
   auth_oidc:
     client_id: homeassistant
     client_secret: !secret oidc_client_secret
     discovery_url: "https://${HALOS_DOMAIN}/sso/.well-known/openid-configuration"
     # Map Authelia groups to HA admin (matches the groups Authelia sends)
     roles:
       admin: "admins"
   ```

   Put the secret in `secrets.yaml`:

   ```yaml
   oidc_client_secret: "<contents of the oidc-secret file from step 1>"
   ```

3. Restart Home Assistant. The login screen gains a "Sign in with HaLOS SSO"
   option (alongside HA's local login, which stays available as a fallback).

## Verify

- Browse to `https://${HALOS_DOMAIN}/homeassistant/` → choose the SSO option →
  authenticate at Authelia → land back in HA, logged in.
- HA's own local accounts still work as an emergency fallback.

## Notes / gotchas

- **Companion app:** point the mobile app at the native `http://${HALOS_DOMAIN}:8123`.
  The SSO option appears in its login flow too (newer app versions support the
  external auth provider); local login remains the fallback.
- **Don't add Traefik forward-auth in front of HA** to "double up" — it breaks
  the API/WebSocket and is redundant with HA's own login. Keep
  `routing.auth.mode: none`.
- If the callback fails, confirm the redirect URI in the Authelia client
  snippet exactly matches what `hass-oidc-auth` requests, and that
  `https://${HALOS_DOMAIN}/homeassistant/` 302-redirects to `:4433`.
