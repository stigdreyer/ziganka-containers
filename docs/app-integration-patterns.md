# Integrating apps behind HaLOS: networking, TLS & SSO

Hard-won patterns for app definitions whose container needs to **talk to HaLOS
services** (Authelia, Home Assistant, other apps) — especially over the
reverse proxy. Read this before wiring a new app into SSO or any
`https://<domain>/...` call, or you'll re-discover the gotchas below the slow
way.

See also: CLAUDE.md ("Routing model"), `homeassistant-oidc.md`,
`musicassistant-sso.md`.

## The two doors (recap)

Every app is reachable two ways:
1. **Native port** — `http://halos.local:<port>` directly on the host. No
   Traefik, no auth.
2. **Per-app TLS port** — Traefik assigns `:4431`–`:443x` (see
   `/etc/halos/port-registry`); `https://halos.local/<app>/` 302-redirects to
   it. TLS is terminated here with the **self-signed HaLOS cert**
   (`CN=halos.local`, issuer `CN=HaLOS Device CA`). `routing.auth.mode` is
   applied on this door only.

The native port is plain HTTP; the proxied port is HTTPS. **MA/SignalK/HA all
serve plain HTTP** to Traefik — never enable in-app SSL (Traefik does TLS).

## Gotcha 1 — containers can't resolve `*.local` (mDNS)

Host networking does **not** give a container mDNS resolution. Any *server-side*
call from inside the container to `https://halos.local/...` fails with
`Cannot connect to host halos.local:NNNN ssl:... [Domain name not found]`.

**Fix:** map the domain to the loopback Traefik listener in the app's compose:

```yaml
network_mode: host
extra_hosts:
  - "${HALOS_DOMAIN}:127.0.0.1"   # HALOS_DOMAIN comes from prestart runtime.env
```

(SignalK shipped this; HA and MA needed it added. Browsers resolve `.local`
fine — this is only for in-container calls.)

## Gotcha 2 — trusting the self-signed HaLOS CA for outbound TLS

The HaLOS CA is already in the **host** bundle `/etc/ssl/certs/ca-certificates.crt`
(so `curl https://halos.local:4433` works on the host without `-k`). Also
downloadable at `https://halos.local/ca/halos-ca.crt`. Getting a *container* to
trust it depends on which trust store the app's code uses:

- **System store / `SSL_CERT_FILE`** (most tools, `ssl.create_default_context()`):
  overlay the host cert dir and/or set `SSL_CERT_FILE`:
  ```yaml
  environment:
    - SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  volumes:
    - /etc/ssl/certs:/etc/ssl/certs:ro   # host bundle has the HaLOS CA
  ```
- **`certifi` (Python `aiohttp` apps, e.g. Music Assistant):** `aiohttp`'s
  `ssl=True` verifies against **certifi's** baked-in `cacert.pem` and **ignores
  `SSL_CERT_FILE` and the system store**. You must append the HaLOS CA into
  certifi's bundle — and because apps **cache their SSL context at startup**,
  it must happen **before the app starts**. Use an entrypoint wrapper:
  ```yaml
  entrypoint:
    - /bin/sh
    - -c
    - "cat /etc/ssl/certs/ca-certificates.crt >> \"$(python3 -c 'import certifi;print(certifi.where())')\"; exec /usr/local/bin/entrypoint.sh <original args>"
  ```
  The container fs resets on every recreate, so this re-applies cleanly each
  start (no unbounded growth). Resolve certifi's path dynamically (survives
  Python version bumps); mirror the image's original entrypoint + args (get
  them from `docker inspect <name> --format '{{json .Config.Entrypoint}}'`).

How to tell which store an app uses — run inside the container:
```bash
docker exec <name> python3 -c "import ssl,socket,certifi
for n,c in [('default',ssl.create_default_context()),('certifi',ssl.create_default_context(cafile=certifi.where()))]:
    try:
        s=c.wrap_socket(socket.socket(),server_hostname='halos.local');s.settimeout(5);s.connect(('127.0.0.1',4433));print(n,'OK');s.close()
    except Exception as e: print(n,'FAIL',type(e).__name__)"
```

## Gotcha 3 — bind-mount directories, not files

`container-packaging-tools`' postinst runs `mkdir -p` on **every bind-mount
host source path**. A **file** source (e.g. `/etc/ssl/certs/ca-certificates.crt`)
makes it fail with `mkdir: cannot create directory '...': File exists`, leaving
the package half-configured. Always mount a **directory** (e.g. `/etc/ssl/certs`)
and reference the file inside it.

## Gotcha 4 — browser vs server-side URL is a single field

App OIDC/SSO config usually has **one** "HA/IdP URL" used for both the
**browser** OAuth redirect (must be a public, browser-reachable HTTPS URL like
`https://halos.local:4433`) **and** the app's **server-side** token/WebSocket
calls (must resolve + verify TLS from inside the container). Satisfy both at once:
- URL = `https://<domain>:<per-app-port>` (browser-reachable, real TLS)
- `extra_hosts` so the container resolves it (Gotcha 1)
- CA trust so server-side verification passes (Gotcha 2)

`http://localhost:<native-port>` is rock-solid server-side but breaks the
browser redirect — don't use it if the app needs end-user OAuth.

## Gotcha 5 (historical) — `host.containers.internal` doesn't resolve for a host-networked app either

Plugins/sidecars that spawn their own managed containers (e.g. Signal K's
`signalk-container`-based plugins, like `signalk-questdb`) may assume the app
is a normal bridge-networked container and have it reach ports the sidecar
publishes on the host via the `host.containers.internal` gateway alias. That
alias is only auto-injected into containers *the sidecar creates*, not into
the app's own container — so a host-networked app (not bridge-networked)
never gets it at all, and any plugin resolving it hits an unresolvable-host
error and silently fails (e.g. `signalk-questdb` staying stuck reporting
"unhealthy").

We carried an `extra_hosts: host.containers.internal:127.0.0.1` workaround in
`signalk-server`'s compose for this (mapping the alias to loopback, since
under host networking, host ports genuinely are the app's own loopback
anyway). **Removed** once `signalk-questdb` 1.5.2 fixed it upstream —
`resolveLanExposureHost` now *probes* `127.0.0.1` before falling back to the
alias, instead of inferring the host from "is this app containerized" (which
doesn't distinguish host- from bridge-networked). See
[signalk-questdb#67](https://github.com/dirkwa/signalk-questdb/issues/67).

Kept here as a reference in case a *different* `signalk-container`-based
plugin hits the same inference bug and hasn't adopted the probe-based fix —
the same `extra_hosts` mapping is the workaround if so.

## SSO / Authelia client registration

HaLOS merges per-app snippets from `/etc/halos/oidc-clients.d/*.yml` into
Authelia and **hashes the `client_secret_file`** for you. Register from the
app's `prestart.sh` (host, runs before container start) so it's portable:
- generate a secret once (`openssl rand -hex 32`) into the app data dir,
- derive the redirect URI from `HALOS_DOMAIN` + the per-app port read from
  `/etc/halos/port-registry` (don't hardcode `:443x`),
- (re)write the snippet every start so URIs track domain/port changes.

See `apps/signalk-server/prestart.sh` and `apps/homeassistant/prestart.sh` for
working examples. Per-app SSO approaches in use:
- **Signal K** — native OIDC; prestart writes the client + secret.
- **Home Assistant** — `hass-oidc-auth` HACS integration; prestart
  auto-registers the Authelia client (`homeassistant-oidc.md`).
- **Music Assistant** — no OIDC; uses HA as the IdP (MA → HA → Authelia) via
  the HA provider (`musicassistant-sso.md`).

## Debugging toolkit (no sudo needed for most)

- App logs (journald): `journalctl -t <container-name> -n 200 --no-pager`
  (the journal display clock can be offset from the app's own timestamps).
- Reachability over the exact loopback+TLS path the container uses:
  `curl -s --resolve halos.local:4433:127.0.0.1 https://halos.local:4433/...`
  (no `-k` = verifies against the host CA, which trusts HaLOS).
- Compose/config files under `/var/lib/container-apps/<pkg>/` and data dirs are
  usually world-readable (owned by the container uid) — readable without sudo.
- `docker`/`docker exec` and editing root-owned files need sudo.
