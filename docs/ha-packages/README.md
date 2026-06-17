# Ziganka HA packages

Home Assistant configuration packages deployed manually to the HALPI2's HA `/config`
volume. They are not part of any `.deb` — they're user-configurable HA YAML, version-controlled
here so changes are tracked and reviewable.

## Files

| File | Deploys to (on HALPI2) | Purpose |
|------|------------------------|---------|
| [`ziganka_alerts.yaml`](ziganka_alerts.yaml) | `/config/packages/ziganka_alerts.yaml` | Signal K alert routing v1 — external buzzer (critical) + Fusion spoken warnings. |

## What it does

Signal K is the single source of truth for alarm severity (`NotificationState`) and how a
condition should be signalled (`NotificationMethod` = `sound`/`visual`). HA only **annunciates**
and provides **acknowledge** — it routes blindly off `state`/`method` and never re-implements
alarm logic. Routing is severity-driven; `method` gates the audible channels.

| State      | Buzzer (Shelly relay) | Fusion (chime + TTS) |
|------------|-----------------------|----------------------|
| emergency  | ✓ continuous          | –                    |
| alarm      | ✓ continuous          | –                    |
| warn       | –                     | ✓ once               |
| alert      | – (ignored)           | –                    |

`normal`/`nominal` = cleared. The visual (LED) channel and mobile push are **out of scope in v1**.

### How it works

- **Ingestion:** the `signalk_ha` integration fires the HA bus event
  `signalk_ziganka_iii_notification` (event_type = `signalk_<slugify(vessel_name)>_notification`)
  with the full payload (`path`, `state`, `method`, `message`, `id`, …).
- **Authoritative active-set:** automations fetch `GET /signalk/v2/api/notifications` inline on
  every event (plus a 10 s backstop + HA start) and set the buzzer relay ON/OFF. The GET is open
  (no auth) and **includes cleared (`state:normal`) entries**, so the logic filters
  `state not in [normal, nominal]`.
- **Buzzer:** ON when any un-muted, active `emergency`/`alarm` still carries method `sound`
  (measured ~0.3 s from event to relay-on). OFF when none remain (event-driven, ≤10 s worst case).
- **Mute switch** → `script.ziganka_mute`: for each sounding notification it `acknowledge`s
  (or `silence`s, per the runtime `status` flags) via the v2 API, cuts the relay immediately, and
  for anything Signal K can neither ack nor silence it records the path locally so the relay
  isn't re-energised until the condition clears.
- **Fusion warn:** **snapshots** the current Fusion source/volume/power, forces the Fusion on +
  AUX (`source2`) + warn volume, then speaks via `media_player.halos`: *"Warning. &lt;message&gt;.
  I repeat. Warning. &lt;message&gt;. End of warning."* (MA auto-prepends its own attention jingle),
  then **restores** the previous source/volume — so e.g. **Bluetooth music resumes** after the
  alert. Uses **fixed delays** (MA announcements don't move the player to `playing`, so
  `wait_template` can't be used; the restore delay is sized to the spoken length so it never fires
  mid-announcement). If the Fusion status reads empty (see caveat) it skips the restore and leaves
  the unit on AUX (graceful fallback).
  - **⚠ Required MA setting (else the message clips):** Music Assistant's Snapserver buffer must be
    lowered or it discards ~1 s off the end of every announcement (cutting the spoken message mid-
    word). Set **Settings → Devices & Services → Music Assistant → Snapcast → "Snapserver buffer
    size" → `250`** (default is `1000`). This lives in MA's config, *not* this package — if MA is
    reinstalled/reset, re-apply it or the warn announcement will clip again.
- **Fail-loud reliability:** if Signal K becomes unreachable for 60 s the buzzer is sounded
  (verified: ~85 s end-to-end) and a persistent notification is raised; if the Shelly goes
  offline a UI/log alert is raised. The critical buzzer path depends only on `signalk_ha` + the
  Shelly — never on Music Assistant, Fusion, Piper, or the cloud.

## Prerequisites (on the HALPI2)

1. **`signalk_ha` integration** installed (HACS) and configured. **Use a single entry**
   (Settings → Devices & Services). A stale duplicate ("Signal K (Unknown Vessel)") should be
   removed — it fires a second event_type and is a wasteful second subscription.
2. **Shelly 1 Gen3 in HA, local mode.** Add via Settings → Devices & Services → Shelly →
   host `192.168.88.227` (no auth). The relay must be **detached** so HA drives the buzzer and
   the switch is a pure mute signal — set on the device:
   ```bash
   curl -X POST http://192.168.88.227/rpc -H 'Content-Type: application/json' \
     -d '{"id":1,"method":"Switch.SetConfig","params":{"id":0,"config":{"in_mode":"detached","initial_state":"off","name":"Buzzer"}}}'
   ```
   Resulting entities: `switch.ziganka_iii_external_alarm` (buzzer),
   `binary_sensor.ziganka_iii_external_alarm_input_0` (mute).
3. **Signal K readwrite token** for HA (ack/silence, Fusion control, test POST). Signal K has
   `allow_readonly:true` (GET open) but writes need auth. Create a device token via the access
   flow and approve it in the Signal K admin UI (Security → Access Requests; Read/Write;
   expiration NEVER):
   ```bash
   curl -X POST http://localhost:3000/signalk/v1/access/requests \
     -H 'Content-Type: application/json' \
     -d '{"clientId":"ha-ziganka-alerts","description":"Home Assistant Ziganka alerts"}'
   # approve in the UI, then GET the returned href to retrieve the token
   ```
   Store it in HA `secrets.yaml` **with the Bearer prefix**:
   ```yaml
   signalk_auth_header: "Bearer <your-signalk-device-token>"
   ```
4. **Music Assistant + Wyoming Piper:** `media_player.halos` and `tts.piper` must exist
   (used only by the warn announcement — not the buzzer).
5. **Packages enabled** in `configuration.yaml`: `homeassistant: packages: !include_dir_named packages`.

## Entities used (verified on the boat)

| Role | Entity |
|------|--------|
| Buzzer relay | `switch.ziganka_iii_external_alarm` |
| Mute switch | `binary_sensor.ziganka_iii_external_alarm_input_0` |
| Fusion/MA player | `media_player.halos` |
| TTS | `tts.piper` |
| Diagnostics | `binary_sensor.ziganka_buzzer_demand`, `binary_sensor.ziganka_signalk_reachable`, `sensor.ziganka_alarm_highest` |
| Tunable | `input_number.ziganka_fusion_warn_volume` (default 14, Fusion 0–24 scale) |

Fusion AUX input = **`source2`** ("Aux") on this device (`GET …/entertainment/device/fusion1/avsource`).

## Deploying

```bash
# From your laptop (1Password SSH agent):
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" \
  scp -o IdentitiesOnly=yes -i "$HOME/.ssh/pubkeys/Halpi2 SSH Key.pub" \
  docs/ha-packages/ziganka_alerts.yaml pi@halos.local:/tmp/

# On the HALPI2:
CFG=/var/lib/container-apps/ziganka-homeassistant-container/data/config
sudo cp /tmp/ziganka_alerts.yaml "$CFG/packages/ziganka_alerts.yaml"
sudo chown root:root "$CFG/packages/ziganka_alerts.yaml"

# Validate, then apply (no restart needed):
sudo docker exec homeassistant python -m homeassistant --script check_config -c /config
curl -X POST -H "Authorization: Bearer <HA_LONG_LIVED_TOKEN>" \
  http://localhost:8123/api/services/homeassistant/reload_all
```
A full HA restart also works and is required the first time the package introduces new top-level
keys.

## Testing

From HA → Developer Tools → Actions (or the API):

- `script.ziganka_alert_test` with `level: warn` → Fusion speaks once, **no buzzer**.
- `script.ziganka_alert_test` with `level: alarm` / `emergency` → **buzzer sounds**.
- Flip the physical **mute switch** (or call `script.ziganka_mute`) → buzzer stops, Signal K
  shows the notification `acknowledged`.
- `script.ziganka_alert_test_clear` → clears the self-test notification(s).

Synthetic notification directly via the API (needs the token):
```bash
curl -X POST http://localhost:3000/signalk/v2/api/notifications \
  -H "Authorization: Bearer <signalk_token>" -H 'Content-Type: application/json' \
  -d '{"state":"alarm","message":"Test","path":"ziganka.selftest","method":["sound","visual"]}'
```

### Verified behaviour (2026-06-17, live)

- alarm/emergency → buzzer ON in ~0.3 s; clear → OFF in ≤~10 s (mute is immediate).
- warn → no buzzer, Fusion announces.
- mute → Signal K `acknowledged`, buzzer off.
- Signal K unreachable 60 s → buzzer fail-loud (~85 s end-to-end) + persistent notification;
  auto-recovers when Signal K returns.

## Troubleshooting

```bash
CFG=/var/lib/container-apps/ziganka-homeassistant-container/data/config
sudo grep -i ziganka "$CFG/home-assistant.log" | tail -30
```
- Buzzer never fires → check `switch.ziganka_iii_external_alarm` is available (Shelly online,
  local) and that the `signalk_ha` bus event fires (Developer Tools → Events, listen to
  `signalk_ziganka_iii_notification`).
- Writes 401 → the `signalk_auth_header` secret is missing/expired; re-provision the token.
- Buzzer won't turn off → confirm the notification actually went `normal`/acknowledged in Signal K
  (`GET /signalk/v2/api/notifications`); the relay follows the active-set.
- **Fusion source control:** the PUT value must be the **short** `sourceN` form (e.g. `source2`
  for AUX). The plugin does `Number("sourceN".substring(6))`, so the full path
  (`entertainment.device.fusion1.avsource.source2`) or a name (`aux1`) → `NaN` → index 0 = AM.
- **Fusion N2K status read-back** — the warn's snapshot/restore (returning you to Bluetooth)
  depends on the Fusion broadcasting its status PGN **130820**. If `GET …/entertainment/device/
  fusion1` shows only `outputAlarms` (no `source`/`volume`), the unit has stopped broadcasting
  status — control (writes) still works, but the warn can't restore the prior source (it falls
  back to leaving the unit on AUX). **Fix: power-cycle the Fusion** (off/on at the head unit) —
  it resumes broadcasting 130820 on startup. Verify with:
  `curl -s localhost:3000/signalk/v1/api/vessels/self/entertainment/device/fusion1` →
  `output.zone1.source.value` should show e.g. `…avsource.source6` (BT).

## Out of scope (v1)

Visual/LED channel (the Govee strip is BLE-only and doubles as cabin lighting — deferred), mobile
push, night-mode volume scaling. v1 is exactly the buzzer + Fusion behaviour above.
