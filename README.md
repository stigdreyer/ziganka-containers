# Ziganka

Custom HaLOS container store and app definitions for the sailing vessel
**Ziganka**, running on a HALPI2 boat computer.

Apps included:
- **Home Assistant** — automation hub for lights, instruments, and media control
- **Music Assistant** — streaming (Spotify, internet radio) and local library,
  with Snapcast for multi-room audio
- **Signal K Server** — marine data hub (NMEA 0183/2000). Forked from
  [halos-marine-containers](https://github.com/halos-org/halos-marine-containers),
  running [dirkwa's fork image](https://github.com/dirkwa/signalk-server) on a
  rolling tag; the image is overridable per-device from Cockpit
- **Snapcast Client** — Snapcast client playing audio out the HDMI port
- **OnaPlotter** — touch-first SignalK chartplotter (AIS, CPA/TCPA, anchor watch, route editing)

Built with the
[container-packaging-tools](https://github.com/halos-org/container-packaging-tools)
pipeline, producing `.deb` packages installable via APT on HaLOS.

## Networking & auth

All apps use **host networking**, but each is still reachable through Traefik on
a per-app HTTPS port (`https://halos.local/<app>/` 302-redirects to it) in
addition to its native port. `routing.auth.mode` is **`none`** for every app —
HA relies on its own login plus optional Authelia SSO, not proxy forward-auth
(see [`docs/homeassistant-oidc.md`](docs/homeassistant-oidc.md)). Signal K wires
into Authelia via its own OIDC client; HA does so via the `hass-oidc-auth` HACS
integration, with the Authelia client auto-registered by the package's
`prestart.sh`.

## Repository layout

```
Halpi2/
├── store/                     # "ziganka" store definition
├── apps/
│   ├── homeassistant/         # Home Assistant Core (+ prestart SSO client reg)
│   ├── music-assistant/       # Music Assistant (incl. bundled Snapserver)
│   ├── signalk-server/        # Signal K Server (fork; configurable image)
│   ├── snapclient/            # Snapcast client → HDMI audio
│   └── ona-plotter/           # OnaPlotter SignalK chartplotter
├── docs/
│   └── homeassistant-oidc.md  # HA ↔ Authelia SSO setup
├── docker/
│   └── ona-plotter/           # CI image build context for OnaPlotter
├── tools/
│   └── build-all.sh           # Build all .deb packages locally
└── .github/workflows/
    ├── build.yml              # Build check on every push
    ├── release.yml            # Build + publish APT repo on version tag
    ├── check-updates.yml      # Daily PR for new HA/MA image versions
    ├── check-snapclient-updates.yml  # Daily PR for new Snapcast releases
    ├── check-signalk-upstream.yml    # Daily PR on upstream Signal K drift
    └── build-ona-plotter-image.yml  # Build + publish OnaPlotter container image
```

## APT repository

Add the Ziganka APT repo to your HALPI2 once:

```bash
curl -fsSL https://stigdreyer.github.io/ziganka-containers/ziganka.gpg \
  | sudo tee /etc/apt/keyrings/ziganka.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/ziganka.gpg] https://stigdreyer.github.io/ziganka-containers stable main" \
  | sudo tee /etc/apt/sources.list.d/ziganka.list
sudo apt update
```

Then install or upgrade apps with standard apt:

```bash
sudo apt install ziganka-container-store ziganka-homeassistant-container \
  ziganka-music-assistant-container ziganka-signalk-server-container \
  ziganka-snapclient-container ziganka-ona-plotter-container
```

> **Signal K note:** the fork shares `app_id`/`client_id`/port 3000 with the
> upstream marine `signalk-server` package and **replaces** it — don't install
> both.

Future updates: `sudo apt update && sudo apt upgrade`

## Building locally

Requires a Debian/Ubuntu host (or Docker on macOS):

```bash
# On Debian/Ubuntu
sudo apt install build-essential dpkg-dev debhelper lintian
# Install uv: https://docs.astral.sh/uv/
./tools/build-all.sh
```

```bash
# On macOS via Docker
docker run --rm -v "$(pwd):/repo" -w /repo debian:bookworm-slim bash -c "
  apt-get update -qq && apt-get install -y -qq \
    build-essential devscripts dpkg-dev debhelper lintian curl ca-certificates git &&
  curl -LsSf https://astral.sh/uv/install.sh | sh &&
  export PATH=\"\$HOME/.local/bin:\$PATH\" &&
  ./tools/build-all.sh"
```

## Releasing

Tag a version to trigger the release workflow:

```bash
git tag v0.3.0 && git push origin v0.3.0
```

GitHub Actions will build the packages, publish them to the APT repository
on GitHub Pages, and attach the `.deb` files to a GitHub Release.

## License

MIT — see [LICENSE](LICENSE). Individual upstream apps retain their own
licenses.
