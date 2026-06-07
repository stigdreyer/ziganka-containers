# Music Assistant SSO (via Home Assistant → Authelia)

Music Assistant has **no native OIDC** and its standalone build has **no direct
Authelia integration**. The only SSO path is **"Sign in with Home Assistant"**,
which chains **MA → HA → Authelia** (since HA is OIDC-backed via
`hass-oidc-auth`, see `homeassistant-oidc.md`).

This requires MA's **Home Assistant provider** to be connected. The
`"Allow User Self-Registration"` toggle and the HA login option only appear
once a provider with domain `hass` exists.

## What the package already handles

`apps/music-assistant/docker-compose.yml` ships the plumbing that makes MA work
behind the HaLOS reverse proxy (see `app-integration-patterns.md` for the why):

- `extra_hosts: ${HALOS_DOMAIN} → 127.0.0.1` so MA resolves `halos.local`
  server-side.
- `/etc/ssl/certs` overlay + `SSL_CERT_FILE` for system-store TLS.
- An **entrypoint wrapper** that appends the HaLOS CA into **certifi's** bundle
  before MA starts — MA (aiohttp) verifies against certifi, which otherwise
  ignores `SSL_CERT_FILE` and can't trust the self-signed cert. This is the
  key fix that lets the HA-OAuth token exchange / WebSocket validate.

So out of the box, MA *can* verify `https://halos.local:4433`.

## One-time setup (in the MA UI)

1. **Settings → Providers → Add Provider → Home Assistant.**
2. **URL** = `https://halos.local:4433` (the per-app HTTPS port — browser-
   reachable for the OAuth popup *and*, with the package plumbing, verifiable
   server-side). **Verify SSL = on**.
3. Authenticate. Two ways:
   - **OAuth** — click "(re)Authenticate", approve the Authelia popup. Allow
     browser pop-ups (esp. Safari/iOS).
   - **Long-lived token** (advanced settings) — paste a token from HA
     (Profile → Security → Long-Lived Access Tokens). Avoids the popup.
4. **Save.** It should persist (provider config lives in MA's `/data` volume,
   so it survives container recreates).
5. **Settings → Core → Web Server → enable "Allow User Self-Registration"**
   (now un-hidden).
6. Log out → **"Sign in with Home Assistant"** on the MA login screen.

## Gotchas seen during setup

- **`Domain name not found`** → `extra_hosts` missing/not applied → MA can't
  resolve `halos.local`. (Shouldn't happen with the shipped compose.)
- **`CERTIFICATE_VERIFY_FAILED` on Save (but the live connection works)** → MA
  verifies via certifi, not the system store; the entrypoint append fixes it.
  If you patch certifi by hand (`docker exec`), you must **`docker restart`**
  (not `systemctl restart`, which recreates the container and wipes it) because
  MA caches its SSL context at startup.
- **`[Errno 22] Invalid argument` on Save** → the verify-**off** code path is
  flaky over the loopback-TLS proxy. Keep **Verify SSL on** (the CA is trusted
  now, so on is correct anyway).
- **Never enable MA's in-app SSL/TLS** — Traefik terminates TLS; MA serves
  plain HTTP on `:8095`. Base URL is `https://halos.local:4431` (public), SSL
  off.

## Verifying

```bash
# certifi (what MA's ssl=True uses) trusts halos.local from inside the container:
sudo docker exec music-assistant python3 -c "import ssl,socket,certifi; c=ssl.create_default_context(cafile=certifi.where()); s=c.wrap_socket(socket.socket(),server_hostname='halos.local'); s.settimeout(5); s.connect(('127.0.0.1',4433)); print('OK'); s.close()"
# MA log shows the provider loaded, no cert errors:
journalctl -t music-assistant -n 50 --no-pager | grep -iE "Loaded plugin provider Home Assistant|CERTIFICATE_VERIFY|providers/save"
```
A reboot is the real test that the entrypoint fix survives a cold recreate.
