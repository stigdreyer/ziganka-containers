# Ziganka Containers

Custom HaLOS container store and app definitions for the sailing vessel **Ziganka**, running on a HALPI2 boat computer (Raspberry Pi-based, arm64, running HaLOS/Debian Trixie).

## What this repo does

Produces Debian `.deb` packages installable via APT on the HALPI2. Each package contains a Docker Compose file, systemd service unit, and config schema for one app. The packages are published to a GitHub Pages APT repository at `https://stigdreyer.github.io/ziganka-containers`.

## Apps

| App | Port | Networking | Image |
|-----|------|-----------|-------|
| Home Assistant | 8123 | bridge (Traefik) | `ghcr.io/home-assistant/home-assistant` |
| Music Assistant | 8095 | bridge (Traefik) | `ghcr.io/music-assistant/server` |
| Snapcast Client | — | host | custom Dockerfile (GitHub releases) |

Host networking apps (Snapclient) are accessed directly on the HALPI2's IP. Bridge apps are proxied via Traefik and accessible through HaLOS's reverse proxy.

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
```

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
