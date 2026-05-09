# Ziganka HA packages

Home Assistant configuration packages that get deployed manually to the HALPI2's HA `/config` volume. They're not part of any `.deb` — these are user-configurable HA YAML, version-controlled here so changes are tracked and reviewable.

## Files

| File | Deploys to (on HALPI2) | Purpose |
|------|------------------------|---------|
| [`ziganka_alerts.yaml`](ziganka_alerts.yaml) | `/config/packages/ziganka_alerts.yaml` | SignalK alert routing — Phase 1 / MVP. Phone push + opportunistic Fusion TTS. |

## Deploying `ziganka_alerts.yaml` (first time)

### 1. Verify prerequisites

On the HALPI2, confirm:

```bash
# Wyoming Piper container is up
sudo systemctl status container-app@wyoming-piper.service
nc -zv localhost 10200   # should succeed

# HA container is up at the new build with env vars
sudo systemctl status container-app@homeassistant.service
docker exec homeassistant printenv | grep -E '^(SIGNALK_URL|FUSION_|ALERT_VOL_)'
```

### 2. Add the Wyoming integration in HA

HA UI → **Settings → Devices & Services → Add Integration → Wyoming Protocol**.
- Host: `localhost`
- Port: `10200`

After it loads you should see a TTS entity (typically `tts.piper`) in Developer Tools → States.

### 3. Enable HA packages (one-time)

Edit `/config/configuration.yaml` and add (or merge into existing top-level `homeassistant:`):

```yaml
homeassistant:
  packages: !include_dir_named packages
```

Then:

```bash
mkdir -p /config/packages
```

### 4. Drop in the package file

```bash
# From your laptop:
scp docs/ha-packages/ziganka_alerts.yaml pi@halos.local:/tmp/
# On the HALPI2:
sudo mv /tmp/ziganka_alerts.yaml /config/packages/
sudo chown root:root /config/packages/ziganka_alerts.yaml
```

(Adjust user/path to match your HA container's volume layout.)

### 5. Restart Home Assistant

HA UI → Developer Tools → YAML → **Restart**.

Watch the log on first boot for parse errors. Common ones:
- `notify.notify` not defined → set `input_text.ziganka_notify_target` to a real notify service name.
- `tts.piper` not found → adjust the `entity_id:` in the `ziganka_alert_play_message` script to your actual Piper TTS entity (Developer Tools → States, search "tts.").
- `media_player.music_assistant` not found → set `input_text.ziganka_ma_player` to your actual MA player entity.

### 6. Customize via the UI

Once HA boots cleanly, go to **Settings → Devices & Services → Helpers** and set:

- `input_text.ziganka_ma_player` → `media_player.halos` (the Fusion stereo media player exposed by the SignalK HA integration)
- `input_text.ziganka_notify_target` → your notify service (`notify.mobile_app_<device>` for one phone, or `notify.notify` to broadcast)
- `input_number.ziganka_vol_*` → adjust if defaults (20/18/14) feel wrong

### 7. Test

Developer Tools → Services → call `script.ziganka_alert_test`. Expect:
- A push notification on your phone titled "⚠ Warning"
- (If the Fusion is on AUX and reachable) chime + spoken "Warning: This is a test of the Ziganka alert system" through the saloon stereo
- (If Fusion is off or on a different source) Fusion is auto-switched to AUX, alert plays, then the original state is restored

## Optional: chime files

For better UX with chimes before TTS, drop three short MP3 files (~1 s each) into `/config/www/alerts/`:

- `emergency.mp3` — fast, urgent (5-pulse pattern matches IMO emergency)
- `alarm.mp3` — moderate (3-pulse)
- `warning.mp3` — gentle (2-pulse)

Free maritime-ish sources: [freesound.org](https://freesound.org) (search "alarm beep"). Without these files the script just plays TTS directly — works fine, just less attention-grabbing.

## Verification cheatsheet

```bash
# On HALPI2 — synthetic alert via SignalK REST API
curl -X POST http://localhost:3000/plugins/signalk-alert-manager/alerts \
  -H 'Content-Type: application/json' \
  -d '{"priority":"warning","message":"Test from curl","path":"test.curl"}'

# Within 3 s, expect: phone push + Fusion TTS (if Fusion is on AUX)
# To clear: POST to /alerts/{id}/acknowledge (or use the push action)
```

If nothing fires, check:
- HA logs: Settings → System → Logs (filter "ziganka")
- `sensor.signalk_active_alerts` state — should reflect the count
- `sensor.signalk_top_alert_id` state — should be the new alert's id
- The alert automation: Settings → Automations → "Ziganka: fire alert handler on new active alert" → Traces

## Phase 2 (not yet)

When the Shelly 1 Gen3 is wired and the Govee strips are paired in HA, a separate `ziganka_alerts_phase2.yaml` package will add buzzer patterns, mute-switch silencing, and LED color cues. Keep them as separate files so they can be enabled/disabled independently.
