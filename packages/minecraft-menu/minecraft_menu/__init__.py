"""Keyboard + gamepad menus for the Minecraft pre-launchers.

Extracted verbatim from modules/minecraft-couch.nix so the couch menu and the
per-machine launcher share one implementation. Nothing here knows about players,
servers or bluetooth; the callers keep that.

Every screen is driven by both a pad and the keyboard, which is what lets a menu be
reached with no controller paired.
"""

import glob
import json
import os
import select
import sys
import termios
import tty

from evdev import InputDevice, ecodes

# D-pad button codes are excluded from "confirm" so a D-pad press can never double as a
# selection.
DPAD_BTNS = {
    ecodes.BTN_DPAD_UP,
    ecodes.BTN_DPAD_DOWN,
    ecodes.BTN_DPAD_LEFT,
    ecodes.BTN_DPAD_RIGHT,
}
DEADZONE = 16000

PAD_GLOB = "/dev/input/couchpad-*"

# Layouts for type_text. NAME_KEYS is what Minecraft accepts in a username; ADDRESS_KEYS
# adds the punctuation a host:port needs.
NAME_KEYS = ["abcdefghij", "klmnopqrst", "uvwxyz0123", "456789_"]
ADDRESS_KEYS = ["abcdefghij", "klmnopqrst", "uvwxyz0123", "456789_.-:"]

SHIFT, BACKSPACE, ACCEPT = "SHIFT", "BACKSPACE", "OK"


# ------------------------------------------------------------------------ storage

def load_json(path, default):
    """Read a JSON file, returning `default` if it does not exist yet."""
    if not os.path.exists(path):
        return default
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def save_json(path, obj):
    """Write atomically, so an interrupted save cannot truncate the file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


# --------------------------------------------------------------------------- pads

def pads(pattern=PAD_GLOB):
    """Resolved event nodes for every joystick, de-duplicated.

    The udev rule tags one symlink per joystick node; resolving and de-duplicating
    guards against a pad that exposes several nodes (motion sensors, force feedback)
    being counted more than once.
    """
    seen = set()
    for link in sorted(glob.glob(pattern)):
        seen.add(os.path.realpath(link))
    return sorted(seen)


# -------------------------------------------------------------------------- input

class Input:
    """Merged keyboard + gamepad event source.

    Yields ("move", dx, dy), ("confirm", devpath|None), ("text", ch), ("backspace",)
    or ("escape",).
    """

    def __init__(self, pattern=PAD_GLOB):
        self.devices = []
        for node in pads(pattern):
            try:
                self.devices.append(InputDevice(node))
            except OSError:
                pass
        self.latched = {}
        self.fd = sys.stdin.fileno()
        self.saved = termios.tcgetattr(self.fd)
        tty.setraw(self.fd)

    def close(self):
        """Restore the terminal and release every pad.

        Releasing matters: SDL has to open them itself when the game starts.
        """
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)
        for dev in self.devices:
            dev.close()
        self.devices = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def _from_pad(self, dev):
        out = []
        for event in dev.read():
            if event.type == ecodes.EV_ABS:
                horiz = event.code in (ecodes.ABS_HAT0X, ecodes.ABS_X)
                vert = event.code in (ecodes.ABS_HAT0Y, ecodes.ABS_Y)
                if not (horiz or vert):
                    continue
                hat = event.code in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y)
                # A hat is already discrete; an analogue axis streams, so latch on the
                # way out and re-arm at centre.
                key = (dev.path, event.code)
                if hat:
                    step = event.value
                elif abs(event.value) > DEADZONE:
                    if self.latched.get(key):
                        continue
                    self.latched[key] = True
                    step = 1 if event.value > 0 else -1
                else:
                    self.latched[key] = False
                    continue
                if not step:
                    continue
                step = 1 if step > 0 else -1
                out.append(("move", step, 0) if horiz else ("move", 0, step))
            elif event.type == ecodes.EV_KEY and event.value == 1:
                if event.code == ecodes.BTN_DPAD_UP:
                    out.append(("move", 0, -1))
                elif event.code == ecodes.BTN_DPAD_DOWN:
                    out.append(("move", 0, 1))
                elif event.code == ecodes.BTN_DPAD_LEFT:
                    out.append(("move", -1, 0))
                elif event.code == ecodes.BTN_DPAD_RIGHT:
                    out.append(("move", 1, 0))
                elif event.code not in DPAD_BTNS:
                    out.append(("confirm", dev.path))
        return out

    def _from_keyboard(self):
        ch = os.read(self.fd, 1).decode("utf-8", "replace")
        if ch == "\x1b":
            rest = ""
            while select.select([self.fd], [], [], 0.02)[0]:
                rest += os.read(self.fd, 1).decode("utf-8", "replace")
            arrows = {"[A": ("move", 0, -1), "[B": ("move", 0, 1),
                      "[C": ("move", 1, 0), "[D": ("move", -1, 0)}
            if rest in arrows:
                return [arrows[rest]]
            return [("escape",)]
        if ch in ("\r", "\n"):
            return [("confirm", None)]
        if ch in ("\x7f", "\b"):
            return [("backspace",)]
        if ch == "\x03":
            raise KeyboardInterrupt
        if ch.isprintable():
            return [("text", ch)]
        return []

    def next(self):
        """Block for the next action."""
        while True:
            fds = [self.fd] + [d.fileno() for d in self.devices]
            ready, _, _ = select.select(fds, [], [])
            for dev in self.devices:
                if dev.fileno() in ready:
                    actions = self._from_pad(dev)
                    if actions:
                        return actions[0]
            if self.fd in ready:
                actions = self._from_keyboard()
                if actions:
                    return actions[0]


# ---------------------------------------------------------------------- rendering

def draw(title, lines, footer=""):
    out = ["\x1b[2J\x1b[H", "", "  " + title, ""]
    out += lines
    out += ["", "  " + footer if footer else ""]
    sys.stdout.write("\r\n".join(out))
    sys.stdout.flush()


def menu(inp, title, options,
         footer="D-pad or arrows to move, any button or Enter to pick"):
    """Vertical picker. Returns the chosen index, or None on escape."""
    cursor = 0
    while True:
        lines = []
        for i, opt in enumerate(options):
            lines.append(("  >  " if i == cursor else "     ") + opt)
        draw(title, lines, footer)
        action = inp.next()
        if action[0] == "move":
            _, _, dy = action
            if dy:
                cursor = (cursor + dy) % len(options)
        elif action[0] == "confirm":
            return cursor
        elif action[0] == "escape":
            return None


def message(inp, title, body):
    draw(title, ["     " + line for line in body], "any button or Enter to continue")
    while True:
        if inp.next()[0] in ("confirm", "escape"):
            return


def confirm(inp, title, body):
    """Yes/no. Returns True only on an explicit yes."""
    draw(title, ["     " + line for line in body], "")
    choice = menu(inp, title, ["No", "Yes"])
    return choice == 1


# --------------------------------------------------------------------- text entry

def type_text(inp, title, keys=None, footer="", validate=None, initial=""):
    """On-screen keyboard; the hardware keyboard types into it too.

    `validate` is called with the text on OK and returns an error string, or None to
    accept. Returns the text, or None on escape.
    """
    keys = keys or NAME_KEYS
    text, shift, row, col = initial, False, 0, 0
    while True:
        rows = []
        for r, chars in enumerate(keys):
            cells = []
            for c, ch in enumerate(chars):
                glyph = ch.upper() if shift else ch
                cells.append("[%s]" % glyph if (r, c) == (row, col) else " %s " % glyph)
            rows.append("     " + "".join(cells))
        extras = [SHIFT, BACKSPACE, ACCEPT]
        cells = []
        for c, label in enumerate(extras):
            cells.append("[%s]" % label if (row, col) == (len(keys), c) else " %s " % label)
        rows.append("     " + "".join(cells))
        draw("%s  %s_" % (title, text), rows, footer)

        action = inp.next()
        kind = action[0]
        if kind == "escape":
            return None
        if kind == "text":
            text += action[1]
            continue
        if kind == "backspace":
            text = text[:-1]
            continue
        if kind == "move":
            _, dx, dy = action
            row = (row + dy) % (len(keys) + 1)
            width = len(extras) if row == len(keys) else len(keys[row])
            col = (col + dx) % width
            col = min(col, width - 1)
            continue
        if kind == "confirm":
            if row == len(keys):
                label = extras[col]
                if label == SHIFT:
                    shift = not shift
                elif label == BACKSPACE:
                    text = text[:-1]
                else:
                    err = validate(text) if validate else None
                    if err:
                        message(inp, "Not usable", [err])
                    else:
                        return text
            else:
                ch = keys[row][col]
                text += ch.upper() if shift else ch
