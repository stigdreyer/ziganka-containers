#!/usr/bin/env python3
"""
3-finger horizontal gesture daemon for HALPI2 / labwc / Wayland
Handles Ctrl+Tab / Ctrl+Shift+Tab tab switching — only when Chromium is focused.
2-finger scroll is handled natively by the display's multitouch mode.

Confirmed working as of 2026-05-12. Maximize/iconify/show-desktop gestures
are NOT implemented here — all approaches tried to date have failed.
See touchgestures.md for a full log of what was attempted.

Deploy to: ~/.config/labwc/touchgestures.py
Autostart: add  python3 ~/.config/labwc/touchgestures.py &  to ~/.config/labwc/autostart
Run as pi user (must be in 'input' group, or sudo):
  WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 python3 ~/.config/labwc/touchgestures.py
"""

import math
import subprocess

from evdev import InputDevice, ecodes

DEVICE_PATH     = "/dev/input/event4"
SWIPE_THRESHOLD = 25.0  # minimum movement (raw units) to register a swipe


def run(cmd):
    subprocess.Popen(cmd.split())


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

    if fingers == 3 and adx > ady:
        if dx < 0:
            run("wtype -M ctrl -k Tab -m ctrl")                   # next tab
        else:
            run("wtype -M ctrl -M shift -k Tab -m shift -m ctrl") # previous tab


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
    print(f"Opening device: {DEVICE_PATH}")
    try:
        dev = InputDevice(DEVICE_PATH)
    except Exception as e:
        print(f"Error opening device: {e}")
        print("Add user to 'input' group and log back in")
        return

    print(f"Listening for gestures on: {dev.name}")

    slots = {i: TouchPoint() for i in range(5)}
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
                    deltas = [s.delta() for s in finished]
                    avg_dx = sum(d[0] for d in deltas) / len(deltas)
                    avg_dy = sum(d[1] for d in deltas) / len(deltas)
                    dist = math.sqrt(avg_dx**2 + avg_dy**2)

                    if dist >= SWIPE_THRESHOLD:
                        n = min(len(finished), 4)
                        print(f"Gesture: {n} fingers, dx={avg_dx:.1f}, dy={avg_dy:.1f}", flush=True)
                        gesture_action(n, avg_dx, avg_dy)
                        gesture_handled = True

                for s in slots.values():
                    s.start_x = None
                    s.start_y = None


if __name__ == "__main__":
    main()
