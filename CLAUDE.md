# Ziganka Containers

Custom HaLOS container store and app definitions for the sailing vessel **Ziganka**, running on a HALPI2 boat computer (Raspberry Pi-based, arm64, running HaLOS/Debian Trixie).

## What this repo does

Produces Debian `.deb` packages installable via APT on the HALPI2. Each package contains a Docker Compose file, systemd service unit, and config schema for one app. The packages are published to a GitHub Pages APT repository at `https://stigdreyer.github.io/ziganka-containers`.

## Apps

| App | Port | Networking | Image |
|-----|------|-----------|-------|
| Home Assistant | 8123 | host | `ghcr.io/home-assistant/home-assistant` |
| Music Assistant | 8095 | host | `ghcr.io/music-assistant/server` |
| Signal K Server | 3000 | host | `ghcr.io/dirkwa/signalk-server:dirkwa` (fork, rolling tag) |
| Snapcast Client | — | host | custom Dockerfile (GitHub releases) |

All current apps use **host networking**. Host networking is mandatory for these: Home Assistant needs it for Bluetooth (BlueZ via D-Bus) and mDNS discovery; Music Assistant needs it so librespot (Spotify Connect) and shairport-sync (AirPlay) advertise the real LAN IP; Signal K needs it for mDNS and direct sensor/serial access.

### Routing model (host networking ≠ no Traefik)

Each app is reachable through **two doors**, and HaLOS auto-generates the Traefik side from the package's `routing.d` declaration — host networking does *not* mean the app bypasses Traefik:

1. **Native port** — directly on the HALPI2's IP (e.g. `http://halos.local:8123`). No Traefik, no auth.
2. **HaLOS proxied port** — Traefik assigns each app a per-app TLS port from `/etc/halos/port-registry` (e.g. `:4431`–`:4435`), and `https://halos.local/<app>/` **302-redirects** to that port. The per-app port router applies the app's `routing.auth.mode`.

Because Traefik proxies to the host port, **forward-auth *can* gate a host-networked app on its proxied port** — it just can't cover the native port. Set `routing.auth.mode` explicitly in `metadata.yaml`; **if omitted, the build tool defaults it to `forward_auth`**, so set it deliberately.

Current `auth.mode`: **all apps = `none`**. HA was previously an accidental `forward_auth` default — now explicitly `none`, because HA already requires its own login on both doors (so forward-auth is redundant, doesn't cover native `:8123`, and breaks the Companion app / WebSocket / `/api/`). SSO for HA is done via app-internal OIDC (`hass-oidc-auth`), not proxy forward-auth — see below.

### Authentication / SSO

HaLOS uses Authelia. Apps tie into Authelia SSO via per-app OIDC (an outbound flow from the app) — and the OIDC redirect resolves fine under host networking, because the `https://halos.local/<app>/...` callback 302-redirects to the app's per-app TLS port:

- **Signal K**: native OIDC support (in this packaging). prestart writes an Authelia client snippet to `/etc/halos/oidc-clients.d/signalk.yml` and a per-host OIDC secret; the `/signalk-server/` → `:4430` redirect makes the callback reach the server. Configured in the app definition here.
- **Home Assistant**: no native OIDC, but the `hass-oidc-auth` HACS integration works against Authelia as an OIDC client (see Authelia's official HA client guide). App-config/HACS change on the HALPI2 — setup steps in `docs/homeassistant-oidc.md`.
- **Music Assistant**: no generic OIDC support yet (only built-in username/password or Home Assistant OAuth). Pointing MA at HA OAuth chains it to the Authelia identity indirectly. Lives in `docs/`.

## Repo layout

```
apps/<app-name>/
  metadata.yaml        # identity, port, tags, default config
  docker-compose.yml   # container definition (pinned image versions)
  config.yml           # user-configurable settings schema
  icon.png             # 256x256 PNG
  assets/              # optional extra files (e.g. Dockerfile for snapclient)
store/
  ziganka.yaml         # store manifest (filters on field::ziganka tag)
  debian/              # dpkg source for the ziganka-container-store package
tools/
  build-all.sh         # builds all .deb packages
.github/workflows/
  build.yml            # CI: build on PR/push; publish apt repo on main push
  release.yml          # tag push: create GitHub Release with .deb files
  check-updates.yml    # daily: PR for new HA/MA image versions
  check-snapclient-updates.yml  # daily: PR for new Snapcast releases
  check-signalk-upstream.yml    # daily: PR when upstream signalk-server definition drifts
```

### Signal K is a fork

`apps/signalk-server/` is forked from `halos-org/halos-marine-containers`. It uses **dirkwa's fork image** on a rolling `:dirkwa` tag (not a pinned semver), mounts the Docker socket, and adds the docker group to `group_add` via a per-host GID resolved in `prestart.sh` (`DOCKER_GID`) — so it stays portable across boats. The image is **overridable per-device** via the `SIGNALK_IMAGE` config field (Cockpit): `docker-compose.yml` uses `image: ${SIGNALK_IMAGE:-…}`, so changing it in Cockpit restarts the service and recreates the container with the new image, no `.deb` change needed. Because the rolling tag has no semver, `check-updates.yml` can't track it; instead `check-signalk-upstream.yml` watches the upstream *definition* (prestart/metadata/compose) and PRs on drift. The fork shares `app_id: signalk-server` / `client_id: signalk` / host port 3000 with the upstream marine package, so it **replaces** it — they cannot coexist.

## Building locally (macOS)

```bash
docker run --rm -v "$(pwd):/repo" -w /repo debian:bookworm-slim bash -c "
  apt-get update -qq && apt-get install -y -qq \
    build-essential devscripts dpkg-dev debhelper lintian curl ca-certificates git &&
  curl -LsSf https://astral.sh/uv/install.sh | sh &&
  export PATH=\"\$HOME/.local/bin:\$PATH\" &&
  ./tools/build-all.sh"
```

Output packages land in `build/`.

## Package naming

All packages are prefixed `ziganka-`. Apps carry the `field::ziganka` debtag so the store filter picks them up.

## Adding a new app

1. Create `apps/<app-name>/` with `metadata.yaml`, `docker-compose.yml`, `config.yml`, `icon.png`
2. Set `field::ziganka` in `tags:` and a `category::` tag matching one in `store/ziganka.yaml`
3. Add a new `category_metadata` entry to `store/ziganka.yaml` if the category is new
4. Run the local build to verify, then push to main — the apt repo publishes automatically

Key fields in `metadata.yaml`:
- `version`: `{upstream_version}-1` (Debian format)
- `upstream_version`: bare upstream version (used by auto-update workflows)
- `web_ui.port`: port the container listens on
- `routing.host_port`: set instead of `web_ui` for host-networked apps with no Traefik proxy

## Releasing

Push to `main` → packages are built and apt repo is updated automatically.

Tag a version for a GitHub Release with attached `.deb` files:
```bash
git tag v0.3.0 && git push origin v0.3.0
```

## Deploying to HALPI2

SSH credentials are stored in 1Password ("Halpi2 SSH Key"). Push/pull to GitHub uses the "GitHub SSH-Key" from 1Password.

```bash
# SCP helper (adjust path to key pub file if needed)
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" \
  scp -o "IdentityFile=/tmp/halpi2_key.pub" -o "IdentitiesOnly=yes" \
  build/*.deb pi@halos.local:~/
```

One-time APT repo setup on the HALPI2:
```bash
curl -fsSL https://stigdreyer.github.io/ziganka-containers/ziganka.gpg \
  | sudo tee /etc/apt/keyrings/ziganka.gpg > /dev/null
echo "deb [arch=all signed-by=/etc/apt/keyrings/ziganka.gpg] https://stigdreyer.github.io/ziganka-containers stable main" \
  | sudo tee /etc/apt/sources.list.d/ziganka.list
sudo apt update
```

## Auto-update workflow

All apps have pinned image versions in `docker-compose.yml`. Three daily GitHub Actions workflows open PRs when upstream releases new versions. Merging a PR triggers a new apt repo publish automatically.

The APT signing key (`APT_SIGNING_KEY`) is stored as a GitHub repository secret.
