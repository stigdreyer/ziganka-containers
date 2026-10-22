# Radar capture for Mayara bug reports

How to record the raw radar traffic Mayara's maintainer asked for in
[mayara-server#722](https://github.com/MarineYachtRadar/mayara-server/issues/722): several minutes
of a vessel at 5–6 km splitting into new target IDs on `nav6820B`, replayable through
`mayara-server --pcap`.

The tool is [`tools/radar-capture.sh`](../tools/radar-capture.sh). It runs **on the HALPI2**.

## Why on the HALPI2 (not a separate bridge)

Mayara's [capture guide](https://github.com/MarineYachtRadar/mayara-server/blob/main/docs/capturing-traffic.md)
assumes a separate capture host, which then needs a bridge or port mirror to see the multicast.
On Ziganka, Mayara itself runs on the HALPI2, so the HALPI2 already receives every spoke Mayara
processes. Capturing there records exactly the input Mayara saw, with no extra hardware and no
risk of breaking the radar link.

What gets recorded, all on the HALPI2's clock:

| File | Contents | Why |
|------|----------|-----|
| `radar.pcap.gz` | Radar ↔ HALPI2 traffic only (the radar host, as reported by Mayara, + Navico multicast groups), full snaplen | Spokes and reports for replay. It **also contains own-ship heading**: the HALO stamps heading into each spoke header, and Mayara sends heading at 10 Hz and COG/SOG at 4 Hz to the HALO (239.238.55.73, 236.6.7.x). |
| `n2k.candump.gz` | Raw NMEA 2000 bus (`candump -L`, epoch timestamps) | Own-ship **position** (not on the radar wire), full-rate heading, and **AIS as ground truth** for the other vessels |
| `mayara.log` | Mayara container log for the capture window | Created/promoted/lost target lines |
| `settings/start-*`, `settings/end-*` | Mayara controls, capabilities and targets for both radars, server version, Signal K sources | Proves the settings were as in #722 |
| `marks.txt`, `marks/` | Your timestamped notes, each with a live target snapshot | Lets the maintainer jump to the interesting minutes |
| `own-ship-history.json` | Signal K history (position/heading/COG/SOG, 1 s) | Convenience copy of own-ship nav |
| `tcpdump.log` | Capture stats, including **packets dropped by kernel** | Should be 0 |

## One-time setup (do this before the trip, at the dock)

1. Copy the script to the HALPI2 (from the Mac, repo root):
   ```bash
   SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" scp -o IdentitiesOnly=yes -i "$HOME/.ssh/pubkeys/Halpi2 SSH Key.pub" tools/radar-capture.sh pi@halos.local:~/
   ```
2. On the HALPI2, install the capture tools:
   ```bash
   sudo apt install -y tcpdump can-utils
   ```
3. With the radar powered and Mayara running, run the preflight:
   ```bash
   sudo ~/radar-capture.sh check
   ```
   Every line should be ✓ and it should end with `READY`. It also prints nav6820B's settings.
4. Do a 1-minute dry run to be sure the detached recorder works: `sudo ~/radar-capture.sh start test`, wait
   a minute, then `sudo ~/radar-capture.sh stop`. Check that `tcpdump.log` says `0 packets dropped by kernel`,
   then delete the test: `sudo rm -r /var/lib/radar-capture/*-test`.

## On the trip

**Settings to keep as in #722** (on nav6820B): ARPA Max Speed **Fast**, Doppler **on**, Doppler
auto-track **on**, guard zone 1 = **5,000–6,000 m, 1°–359°**. `check` prints them. Don't change them
during the capture.

1. **Put the radar in standby.** SSH to the HALPI2 and run `sudo ~/radar-capture.sh check`.
2. **Start recording:** `sudo ~/radar-capture.sh start split`
3. Wait ~10 s in standby, then **set the radar to transmit**. (The maintainer wants a few seconds of
   standby → transmit at the start.)
4. **Record the problem.** When a vessel is at 5–6 km in nav6820B's zone and starts getting new IDs,
   add a mark so it's easy to find:
   ```bash
   sudo ~/radar-capture.sh mark "vessel at 5.5 km bearing 220, splitting"
   ```
   Keep going for **several minutes** of the problem; longer is better. Add more marks whenever
   something notable happens (new ID for the same vessel, track jumps to another vessel, ghost near the
   boat).
5. **Stop:** `sudo ~/radar-capture.sh stop`. It collects the logs and settings, then gzips everything
   (can take a minute). It prints the files, the tcpdump drop count and your marks.

Notes:
- The recorder runs as a systemd service (`radar-capture`), so **it keeps recording if your SSH session
  or laptop drops.** `sudo ~/radar-capture.sh status` shows progress from any new session.
- It **stops itself** after 45 min (`sudo MAX_MINUTES=60 ~/radar-capture.sh start …` to change), if free
  disk drops below 2 GB, or if tcpdump or candump dies. The reason is written to `marks.txt`.
- Expect a few hundred MB per 5 minutes uncompressed; the gzipped pcap is much smaller.
- Captures are kept in `/var/lib/radar-capture/<UTC-time>-<label>/`.

## After the trip

1. Copy the capture to the Mac:
   ```bash
   SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" scp -r -o IdentitiesOnly=yes -i "$HOME/.ssh/pubkeys/Halpi2 SSH Key.pub" pi@halos.local:/var/lib/radar-capture/ ~/Desktop/radar-capture/
   ```
2. **Privacy review before sharing:**
   - `radar.pcap.gz`: only radar ↔ HALPI2 traffic, i.e. the MAC and IP of the HALO and the HALPI2, plus own
     heading/COG/SOG. **No position, no AIS.** Fine to attach to the public issue.
   - `n2k.candump.gz`: contains **your GPS track** and **other vessels' AIS** (names, MMSIs,
     positions). Don't attach it publicly. Tell the maintainer it exists and send it privately if he wants
     it (he offered to accept files privately).
   - `own-ship-history.json`: your GPS track, so private for the same reason.
   - `settings/*-targets-*.json`, `marks/`: target positions include lat/lon, so private as well.
     `settings/*-controls-*`, `*-capabilities-*` and `*-mayara-server.json` are fine to share.
   - `mayara.log`: contains target lat/lon in the "Created/Promoted" lines. Share it privately, or ask
     Claude to convert positions to range/bearing, as in #723.
3. Reply on #722 with the pcap attached (GitHub accepts `.gz` up to 25 MB; for larger files use a link),
   the marks with UTC times, the Mayara version from `settings/start-mayara-server.json`, and a note that
   heading/COG/SOG are on the wire in the pcap while position comes over NMEA 2000 (available privately as
   a candump).

## Troubleshooting

- `✗ nothing received from the radar` → radar off, or not cabled to the network. `check` only counts packets
  **from** the radar, because Mayara's own heading/nav packets to it flow even when it's off. With the radar on,
  `check` says `STANDBY` (reports only) or `TRANSMITTING` (spoke fragments). Either is fine for starting a capture.
- `✗ no CAN interface found` → `ip -br link` and set it explicitly: `sudo CAN_IF=can0 ~/radar-capture.sh check`.
- `packets dropped by kernel` > 0 → the HALPI2 was too busy. Close the Mayara web UI on other screens and
  try again. Small counts (< 0.1 %) are worth mentioning to the maintainer but are still usable.
- Recorder stopped early → see the last lines of `marks.txt` and `journalctl -u radar-capture`.
