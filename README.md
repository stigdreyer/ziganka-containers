# Ziganka

Custom HaLOS container store and app definitions for the sailing vessel
**Ziganka**, running on a HALPI2 boat computer.

Apps included:
- **Home Assistant** — automation hub for lights, instruments, and media control
- **Music Assistant** — streaming (Spotify, internet radio) and local library,
  with Snapcast for multi-room audio
- **Snapcast Client** — Snapcast client playing audio out the HDMI port
- **Mayara** — marine radar display with ARPA tracking and AIS overlay
- **OnaPlotter** — touch-first SignalK chartplotter (AIS, CPA/TCPA, anchor watch, route editing)

Built with the
[container-packaging-tools](https://github.com/halos-org/container-packaging-tools)
pipeline, producing `.deb` packages installable via APT on HaLOS.

## Repository layout

```
Halpi2/
├── store/                     # "ziganka" store definition
├── apps/
│   ├── homeassistant/         # Home Assistant Core
│   ├── music-assistant/       # Music Assistant (incl. bundled Snapserver)
│   ├── snapclient/            # Snapcast client → HDMI audio
│   ├── mayara/                # Mayara radar server
│   └── ona-plotter/           # OnaPlotter SignalK chartplotter
├── docker/
│   └── ona-plotter/           # CI image build context for OnaPlotter
├── tools/
│   └── build-all.sh           # Build all .deb packages locally
└── .github/workflows/
    ├── build.yml              # Build check on every push
    ├── release.yml            # Build + publish APT repo on version tag
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
  ziganka-music-assistant-container ziganka-snapclient-container \
  ziganka-mayara-container ziganka-ona-plotter-container
```

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
