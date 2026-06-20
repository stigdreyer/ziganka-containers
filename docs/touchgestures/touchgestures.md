# Touchscreen Gesture Setup — HALPI2 / Raspberry Pi

## System Context

- **Hardware**: HALPI2 (Raspberry Pi-based mini PC)
- **Display**: Waveshare 8DP-CAPLCD (8 inch, 1280x800, capacitive touch)
- **OS**: Raspberry Pi OS Bookworm (arm64)
- **Window manager**: labwc **0.9.7** (Wayland compositor) — was 0.9.2; see the uinput update below

> ## ⚠ Update (2026-06): labwc 0.9.7 broke `wtype` → switched to uinput
>
> After labwc updated **0.9.2 → 0.9.7**, `wtype` keystrokes stopped reaching
> Chromium entirely (the daemon detected gestures fine — verified in the log —
> but `wtype -k F11` / `Ctrl+Tab` had no effect; `wtype` exits 0 but labwc no
> longer delivers its Wayland virtual keyboard to the focused client).
>
> **Fix:** the daemon now injects keys via **uinput** (`evdev.UInput`) — a
> kernel-level virtual keyboard that labwc routes to the focused window like any
> real keyboard. Confirmed working (5-finger pinch toggles fullscreen, 4-finger
> swipe switches tabs). Requirements (set up on the HALPI2):
>
> ```bash
> # /dev/uinput access for the 'input' group (pi is already a member):
> echo 'KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' \
>   | sudo tee /etc/udev/rules.d/99-uinput.rules
> # load the uinput module at boot:
> echo uinput | sudo tee /etc/modules-load.d/uinput.conf
> ```
>
> `wlrctl` is still used only for the *focus check* (`wlrctl window list`), which
> needs the Wayland env (`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`); key injection no
> longer depends on the Wayland protocol.
- **Browser**: Chromium (`/usr/bin/chromium`)
- **Input device**: `/dev/input/event4` (Waveshare, usb:0712:000a)

## Raw Device Info

```
Device:        Waveshare  Waveshare
Kernel:        /dev/input/event4
Id:            usb:0712:000a
Capabilities:  touch
Size:          640x267mm
ntouches:      10
Scroll methods: none
```

The Waveshare registers in libinput as a pure **touch device** (not a touchpad), which means:
- `libinput-gestures`, `fusuma`, and labwc native rc.xml gestures all require libinput gesture events — none work with this device
- 2-finger scrolling does not work out of the box
- Raw evdev tools work because the device correctly reports multitouch (up to 10 slots)

## Available Tools

All available in Raspberry Pi OS Bookworm repos:
```bash
sudo apt install python3-evdev wtype wlrctl
```

- **`python3-evdev`** — reads raw ABS_MT_* multitouch events directly from `/dev/input/event4`
- **`wtype`** — sends keyboard/mouse events on Wayland. Modifier names: `ctrl`, `shift`, `alt`, `logo` (Super/Win key). NOT `super`.
- **`wlrctl`** — controls labwc windows/outputs on Wayland

Tools NOT in repos (not worth pursuing): `ydotool` (needs cmake build), `touchegg` (Ubuntu only, no arm64 package).

---

## What Works

### 3-finger horizontal swipe → tab switching

**Status: CONFIRMED WORKING**

Python daemon reading raw evdev events, firing `wtype` keystroke on lift:

```python
# 3-finger swipe left → Ctrl+Tab (next tab)
run("wtype -M ctrl -k Tab -m ctrl")

# 3-finger swipe right → Ctrl+Shift+Tab (previous tab)
run("wtype -M ctrl -M shift -k Tab -m shift -m ctrl")
```

Tested and confirmed working in Chromium.

### 2-finger scroll

**Status: RESOLVED — not by code**

Resolved by switching the Waveshare display to native multitouch mode in its firmware settings. No software workaround needed or in place.

---

## What Does NOT Work

### labwc `<gestures>` in rc.xml (labwc 0.9.2)

**Attempted:**
```xml
<gestures>
  <swipe fingers="3" direction="up"><action name="Maximize"/></swipe>
  <swipe fingers="3" direction="down"><action name="Iconify"/></swipe>
  <swipe fingers="4" direction="up"><action name="ShowDesktop"/></swipe>
</gestures>
```

**Result:**
- 3-finger swipe up → showed desktop (wrong action, expected maximize)
- 3-finger swipe down → resized browser window to ~50% height (unexpected behavior)
- 4-finger swipe up → did nothing

**Root cause:** labwc 0.9.2 intercepts 3-finger raw touch events natively with its own built-in gesture handler regardless of what's in `<gestures>`. The `<gestures>` block either fires alongside or overrides with wrong behavior. This configuration approach is not reliable on this device+labwc version.

**Do not retry** without confirming labwc version ≥ 0.9.x with a known-working `<gestures>` implementation.

### Running Python daemon alongside labwc gesture handling

**Attempted:** Python script handles all gestures (horizontal + vertical + 4-finger), deployed to `~/.config/labwc/autostart`.

**Result:** labwc natively intercepts 3-finger touch swipes and fires its own actions. Both labwc AND the Python script receive the same raw touch events simultaneously (no exclusive device grab). This causes gesture double-firing and incorrect behavior (3-finger up showed desktop instead of maximizing).

**Fix attempted:** Delegate vertical/4-finger to labwc `<gestures>`, keep Python for horizontal only. Failed because `<gestures>` itself doesn't work correctly (see above).

### wlrctl window maximize/minimize

**Attempted:**
```bash
wlrctl window maximize
wlrctl window minimize
```

**Result:**
- `maximize` toggled — if window was already maximized, it restored it instead
- `minimize` silently failed (no error, no effect)
- wlrctl version 0.2.2

**Do not use** wlrctl for maximize/minimize.

### wtype Super key modifier name

**Common mistake:** Using `super` as the modifier name.

```bash
# WRONG — fails silently
wtype -M super -k Up -m super

# CORRECT
wtype -M logo -k Up -m logo
```

The correct modifier name for the Super/Windows key in wtype is `logo`, not `super`.

### rc.xml keyboard binding syntax

**Common mistake:** Using `Super-Up` style modifier syntax in labwc rc.xml keybindings.

```xml
<!-- WRONG — silently ignored -->
<keybind key="Super-Up"><action name="Maximize"/></keybind>

<!-- CORRECT — single letter modifiers -->
<keybind key="W-Up"><action name="Maximize"/></keybind>
```

labwc rc.xml uses single-letter modifier prefixes: `W` = Super/Win, `A` = Alt, `C` = Ctrl, `S` = Shift.

### 2-finger scroll via Python/uinput (Phase 1 — abandoned)

**Attempted:** Multiple approaches to inject scroll events via:
- `wlrctl pointer scroll {amount}` — rejected "vertical"/"horizontal" axis argument
- `wtype` scroll simulation
- UInput virtual device with `REL_WHEEL` and `REL_WHEEL_HI_RES`
- Accumulator, direction locking, rate limiting, fixed amounts

**Result:** Persistent jitter regardless of approach. Raw touch data was clean (no sign alternation in device output). Jitter source was likely Chromium's animation handling of discrete scroll events injected as synthetic input.

**Resolution:** User switched Waveshare display to native multitouch mode, which gave proper 2-finger scroll without any software involvement.

### `pkill -f <pattern>` over SSH

**Gotcha:** `pkill -f touchgestures` matches the SSH session's own command string (because `-f` matches the full command line, which includes the pattern string being passed via SSH). This causes pkill to kill its own parent shell, dropping the SSH connection with exit code 255.

**Workaround:** Use `kill $(pgrep -f "python3.*touchgestures")` or match a more specific pattern that won't appear in the SSH command string itself, e.g. `pgrep -f "python3.*gesture"`.

---

## Input Group Access

To run the Python daemon without sudo, user must be in the `input` group:
```bash
sudo gpasswd -a $USER input
# log out and back in
```

Temporary workaround without re-login: `sg input -c "python3 ..."` or `sudo python3 ...`

---

## Useful Diagnostic Commands

```bash
# List input devices
libinput list-devices

# Watch raw touch events live
sudo libinput debug-events

# Check Wayland outputs
wlrctl output list

# Test wtype (should type 'hello' into focused window)
wtype hello

# Test wlrctl
wlrctl window focus

# Watch gesture daemon output live
tail -f /tmp/touchgestures.log
```

## wtype Key Reference

```bash
wtype -k F11                                            # single key
wtype -M ctrl -k Tab -m ctrl                            # Ctrl+Tab
wtype -M ctrl -M shift -k Tab -m shift -m ctrl          # Ctrl+Shift+Tab
wtype -M logo -k d -m logo                              # Super+D
```

## wlrctl Reference

```bash
wlrctl window fullscreen              # fullscreen focused window (toggle)
wlrctl window maximize                # maximize focused window (TOGGLES — avoid)
wlrctl window minimize                # minimize focused window (BROKEN in 0.2.2)
wlrctl output list                    # list outputs
wlrctl window list                    # list open windows (format: "app_id: title")
```

`wlrctl window list` output format is `chromium: Music Assistant - Chromium` — check for "chromium" to detect browser focus.

## SSH to HALPI2

SSH credentials stored in 1Password ("Halpi2 SSH Key").

```bash
# Export the right public key to avoid "too many authentication failures"
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" \
  ssh-add -L | grep Halpi2 > /tmp/halpi2_key.pub

# Then use IdentitiesOnly to force the correct key
SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" \
  ssh -o "IdentitiesOnly=yes" -o "IdentityFile=/tmp/halpi2_key.pub" pi@halos.local
```

## Touch Coordinate Inversion (display rotation)

If HaLOS settings are used to rotate the display, the Waveshare touch device's raw evdev coordinates do **not** rotate with it. Symptoms: touching top-right registers as bottom-left (or similar axis inversion).

**Fix:** add a udev calibration matrix matching the display rotation.

For 180° rotation (the common HaLOS default on this display):

```bash
sudo tee /etc/udev/rules.d/99-waveshare-touch.rules <<'EOF'
SUBSYSTEM=="input", ATTRS{idVendor}=="0712", ATTRS{idProduct}=="000a", \
  ENV{LIBINPUT_CALIBRATION_MATRIX}="-1 0 1 0 -1 1 0 0 1"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

**Note:** `udevadm trigger` alone does not re-initialize an already-open input device. A **reboot is required** for the calibration matrix to take effect.

To check the current display transform: `WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 wlr-randr` — look for the `Transform:` line.

Matrix reference:

| Transform | LIBINPUT_CALIBRATION_MATRIX |
|-----------|----------------------------|
| 90°       | `0 1 0 -1 0 1 0 0 1`       |
| 180°      | `-1 0 1 0 -1 1 0 0 1`      |
| 270°      | `0 -1 1 1 0 0 0 0 1`       |

---

## Current State (as of 2026-05-12)

HALPI2 is in vanilla state — no gesture daemon, no `<gestures>` in rc.xml, no touchgestures.py installed.

**Only confirmed working gesture:** 3-finger horizontal swipe for tab switching, but currently not deployed.

All maximize/minimize/show-desktop gesture approaches tried to date have failed. This remains an open problem.
