#!/usr/bin/env python3
"""
Touch gesture daemon for HALPI2 / labwc / Wayland (Chromium kiosk).

Gestures (only when Chromium is focused):
  - 4-finger horizontal swipe  -> Ctrl+Tab / Ctrl+Shift+Tab (switch tabs)
  - 5-finger pinch (converge)  -> F11 (toggle Chromium fullscreen)
2-finger scroll is handled natively by the display's multitouch mode.
3-finger and vertical/4-finger labwc-native gestures are avoided — labwc 0.9.2
intercepts 3-finger raw swipes; see touchgestures.md for the full log.

The touchscreen is found by name (TOUCH_NAME_MATCH) because /dev/input/eventN
numbering shuffles across reboots.

Deploy to: ~/.config/labwc/touchgestures.py
Autostart: add  python3 ~/.config/labwc/touchgestures.py &  to ~/.config/labwc/autostart
Keystrokes are injected via uinput (kernel-level virtual keyboard), NOT wtype —
labwc 0.9.x does not deliver wtype's Wayland virtual keyboard to Chromium. This
needs /dev/uinput access (a udev rule granting the 'input' group; see
touchgestures.md). wlrctl (focus check) still needs the Wayland env below.

Run as pi user (must be in 'input' group, or sudo):
  WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 python3 ~/.config/labwc/touchgestures.py
"""

import math
import subprocess
import time

from evdev import InputDevice, UInput, ecodes, list_devices

# Find the touchscreen by name — /dev/input/eventN numbering shuffles across
# reboots (e.g. event4 -> event1), so never hardcode the path.
TOUCH_NAME_MATCH = "waveshare"   # substring of the device name, case-insensitive
SWIPE_THRESHOLD  = 25.0          # minimum movement (raw units) to register a swipe
# 5-finger pinch -> toggle fullscreen. Pinch = fingers converging: the average
# distance from their centroid shrinks. Tune via the debug output if needed.
PINCH_FINGERS    = 5
PINCH_RATIO      = 0.7           # end spread <= 70% of start spread = pinch-in
MIN_PINCH_SPREAD = 50.0          # min start spread so 5 fingers placed close
                                 # together don't false-trigger


def find_touch_device():
    """Return the multitouch touchscreen InputDevice, or None.

    Prefers a device whose name matches TOUCH_NAME_MATCH; falls back to any
    device exposing multitouch (ABS_MT_POSITION_X)."""
    fallback = None
    for path in list_devices():
        try:
            d = InputDevice(path)
        except Exception:
            continue
        abs_caps = d.capabilities().get(ecodes.EV_ABS, [])
        codes = [c if isinstance(c, int) else c[0] for c in abs_caps]
        if ecodes.ABS_MT_POSITION_X not in codes:
            continue
        if TOUCH_NAME_MATCH in d.name.lower():
            return d
        if fallback is None:
            fallback = d
    return fallback


# Kernel-level virtual keyboard (created in main). wtype's Wayland virtual
# keyboard is NOT delivered to Chromium by labwc 0.9.x, so we inject real input
# events via uinput instead; labwc routes them to the focused window normally.
# Needs /dev/uinput access (input group; see the udev rule in touchgestures.md).
UI = None


def make_keyboard():
    caps = {ecodes.EV_KEY: [ecodes.KEY_LEFTCTRL, ecodes.KEY_LEFTSHIFT,
                            ecodes.KEY_TAB, ecodes.KEY_F11]}
    return UInput(caps, name="ziganka-gestures")


def tap(*keys):
    """Press keys in order, release in reverse, via the uinput keyboard."""
    if UI is None:
        return
    for k in keys:
        UI.write(ecodes.EV_KEY, k, 1)
    UI.syn()
    time.sleep(0.02)
    for k in reversed(keys):
        UI.write(ecodes.EV_KEY, k, 0)
    UI.syn()


def is_browser_focused():
    """
    Returns True if Chromium is open. wlrctl window list does not report
    focus state, so we check for presence. Acceptable on a single-window
    boat computer.
    """
    try:
        r = subprocess.run(
            ["wlrctl", "window", "list"],
            capture_output=True, text=True, timeout=0.5
        )
        return any("chromium" in line.lower() for line in r.stdout.splitlines())
    except Exception:
        return True  # fail open if wlrctl unavailable


def gesture_action(fingers, dx, dy):
    adx, ady = abs(dx), abs(dy)

    if not is_browser_focused():
        return

    if fingers == 4 and adx > ady:
        if dx < 0:
            tap(ecodes.KEY_LEFTCTRL, ecodes.KEY_TAB)                        # next tab
        else:
            tap(ecodes.KEY_LEFTCTRL, ecodes.KEY_LEFTSHIFT, ecodes.KEY_TAB)  # previous tab


def toggle_fullscreen():
    """5-finger pinch -> F11. Toggles Chromium fullscreen <-> windowed."""
    if not is_browser_focused():
        return
    tap(ecodes.KEY_F11)


class TouchPoint:
    def __init__(self):
        self.x = None
        self.y = None
        self.start_x = None
        self.start_y = None
        self.active = False

    def move(self, x=None, y=None):
        if x is not None:
            self.x = x
        if y is not None:
            self.y = y

    def delta(self):
        if self.start_x is None:
            return 0, 0
        return self.x - self.start_x, self.y - self.start_y

    def up(self):
        self.active = False


def main():
    global UI
    dev = find_touch_device()
    if dev is None:
        print("No multitouch touchscreen found "
              "(is the user in the 'input' group?)")
        return

    try:
        UI = make_keyboard()
        time.sleep(1.0)  # let the compositor register the new keyboard device
    except Exception as exc:
        print(f"Could not create uinput keyboard ({exc}); "
              "is /dev/uinput accessible (input group)?")
        UI = None

    print(f"Listening for gestures on: {dev.name} ({dev.path})")

    slots = {i: TouchPoint() for i in range(10)}  # Waveshare reports up to 10
    current_slot = 0
    active_slots = set()
    gesture_handled = False

    for event in dev.read_loop():
        if event.type == ecodes.EV_ABS:
            if event.code == ecodes.ABS_MT_SLOT:
                current_slot = event.value

            elif event.code == ecodes.ABS_MT_TRACKING_ID:
                if event.value == -1:
                    slots[current_slot].up()
                    active_slots.discard(current_slot)
                else:
                    s = slots[current_slot]
                    s.x = None; s.y = None
                    s.start_x = None; s.start_y = None
                    s.active = True
                    active_slots.add(current_slot)
                    gesture_handled = False

            elif event.code == ecodes.ABS_MT_POSITION_X:
                s = slots[current_slot]
                if s.start_x is None:
                    s.start_x = event.value
                    s.x = event.value
                else:
                    s.move(x=event.value)

            elif event.code == ecodes.ABS_MT_POSITION_Y:
                s = slots[current_slot]
                if s.start_y is None:
                    s.start_y = event.value
                    s.y = event.value
                else:
                    s.move(y=event.value)

        elif event.type == ecodes.EV_SYN and event.code == ecodes.SYN_REPORT:
            if len(active_slots) == 0 and not gesture_handled:
                finished = [s for s in slots.values()
                            if s.start_x is not None and not s.active]

                if len(finished) >= 3:
                    count = len(finished)
                    deltas = [s.delta() for s in finished]
                    avg_dx = sum(d[0] for d in deltas) / count
                    avg_dy = sum(d[1] for d in deltas) / count
                    dist = math.hypot(avg_dx, avg_dy)

                    # 5-finger pinch -> toggle fullscreen (F11).
                    pinched = False
                    if count >= PINCH_FINGERS:
                        sxc = sum(s.start_x for s in finished) / count
                        syc = sum(s.start_y for s in finished) / count
                        exc = sum(s.x for s in finished) / count
                        eyc = sum(s.y for s in finished) / count
                        start_spread = sum(math.hypot(s.start_x - sxc, s.start_y - syc)
                                           for s in finished) / count
                        end_spread = sum(math.hypot(s.x - exc, s.y - eyc)
                                         for s in finished) / count
                        ratio = end_spread / start_spread if start_spread else 1.0
                        print(f"{count}-finger: start_spread={start_spread:.0f} "
                              f"end_spread={end_spread:.0f} ratio={ratio:.2f}", flush=True)
                        pinched = (start_spread >= MIN_PINCH_SPREAD
                                   and ratio <= PINCH_RATIO)

                    if pinched:
                        print(f"Gesture: {count}-finger pinch -> F11", flush=True)
                        toggle_fullscreen()
                        gesture_handled = True
                    elif dist >= SWIPE_THRESHOLD:
                        n = min(count, 4)
                        print(f"Gesture: {n} fingers, dx={avg_dx:.1f}, dy={avg_dy:.1f}", flush=True)
                        gesture_action(n, avg_dx, avg_dy)
                        gesture_handled = True

                for s in slots.values():
                    s.start_x = None
                    s.start_y = None


if __name__ == "__main__":
    main()
