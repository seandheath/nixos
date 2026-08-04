{ config, pkgs, lib, ... }:
# Couch Minecraft on hydrogen: 1-4 Bluetooth gamepads driving 1-4 tiled Minecraft
# clients on the projector, launched from a single GNOME icon. Full runbook
# (creating the Prism instance, installing mods) is docs/minecraft.md.
#
# ARCHITECTURE, and why each layer exists:
#
#   .desktop icon  ->  minecraft-couch          (runs inside the GNOME session)
#     -> systemd  minecraft-couch.service       (a REAL login session on tty7)
#       -> Hyprland with a generated config     (tiles; no bars, no idle, no lock)
#         -> minecraft-couch-spawn              (places N windows via hyprctl)
#           -> minecraft-couch-menu             (the pre-launcher; see below)
#           -> minecraft-couch-player NAME NODE (bubblewrap: exactly one gamepad)
#             -> prismlauncher -d <per-player data dir> -s 127.0.0.1:25565
#
# WHY A PRE-LAUNCHER RATHER THAN PINNED CONTROLLERS. This used to key each seat to a
# controller's Bluetooth MAC in a udev rule, which made identity a property of the
# HARDWARE: pick up a sibling's pad and you logged in as your sibling, "2 players"
# always meant seats 1 and 2 (so the third and fourth child's pads did nothing), and
# four MACs had to be collected by hand before anything worked at all. Asking each
# player who they are at session start makes identity a property of the PERSON, and
# the question the MAC answered -- "which event node is seat N's pad?" -- simply
# stops being asked: whichever node a child confirms on is the node bound into their
# sandbox. Pads are interchangeable, and only the pads actually powered on get a seat.
#
# The roster is runtime state for the same reason: players get added over time, and
# nobody should need to edit Nix and rebuild to let a friend play. The pre-launcher
# also pairs and unpairs controllers, because the couch session is Hyprland on tty7
# with GNOME inactive -- GNOME's Bluetooth panel is simply not reachable from here.
#
# WHY THE MENU TAKES KEYBOARD *AND* GAMEPAD. Chicken-and-egg: with no pad yet paired
# there would be no way to drive a gamepad-only menu to the pairing screen. hydrogen
# has a wired keyboard (Dell KB216), so every screen accepts both.
#
# WHY A SEPARATE VT RATHER THAN A NESTED COMPOSITOR. GNOME must keep running --
# RustDesk's ScreenCast capture depends on that session (hosts/hydrogen.nix), and
# gnome-remote-desktop and Sunshine were already abandoned on this box, so it is
# not something to disturb. But Mutter cannot tile into quadrants, cannot let a
# client position itself, and cannot fullscreen a nested compositor's window.
# Running Hyprland as its own logind session on tty7 sidesteps all of that: the VT
# switch makes GNOME inactive, it releases DRM master, and Hyprland gets the GPU
# natively -- no double compositing, no explicit-sync surprises. Switching back
# reactivates GNOME. `PAMName=login` + `TTYPath` is what makes logind register the
# unit as a real session; without it Hyprland cannot take DRM master.
#
# WHY ONE PRISM DATA DIR PER PLAYER. Prism refuses to run twice, keyed on
# ApplicationId::fromPathAndVersion(dataPath, version) -- a second
# `prismlauncher --launch` would just message the first process, which would then
# spawn the game OUTSIDE the second sandbox and every character would move in
# unison. Distinct `-d` directories give distinct application IDs. They are not
# full copies: minecraft-couch-sync symlinks the heavy shared trees (and the mods
# folder) back to the canonical install, so mods are installed once in one place --
# which since the mod set went declarative means the Nix store
# (packages/minecraft-client-mods.nix), two hops along the same symlink chain.
#
# WHY BUBBLEWRAP. Gamepad input is read straight from /dev/input via evdev and
# never touches the display server, so by default every client sees every pad.
# Each client is therefore launched with a tmpfs over /dev/input and only its own
# player's event node bound back in.
{
  imports = [
    # The controllers are Bluetooth and hydrogen enables no Bluetooth stack of its
    # own (it never needed one). Shared module, deduplicated if anything else
    # pulls it in.
    ../modules/bluetooth.nix
  ];

  config =
    let
      # ---------------------------------------------------------------------
      # SEED roster only. The live roster is JSON under the user's home (see
      # rosterFile) and is created from this list the first time the menu runs;
      # after that the file is authoritative and this list is inert.
      #
      # FOOTGUN: editing these names later will NOT change an existing roster.
      # Add and remove players in the pre-launcher; to re-seed from Nix, delete
      # the JSON file. Predictable beats clever -- a merge would fight the
      # "Remove a player" action every time the menu started.
      #
      # Names are load-bearing in one direction: an offline UUID is a hash of the
      # username, so RENAMING a player after they have played orphans that
      # character's inventory, advancements and ender chest. Removing and
      # re-adding the identical name is safe and returns the same character.
      # ---------------------------------------------------------------------
      seedPlayers = [
        "GentlemenPupil"
        "VizualWanderer"
        "PhantomSpecialst"
        "MadDreamer"
        "LuckyObserver" # sheath, when playing from the couch rather than sulfur
      ];

      # Minecraft caps usernames at 16 characters and enforces it on the wire: an
      # over-long name fails to encode the login packet, so the client cannot
      # connect at all. The menu applies the same rule to names typed at runtime.
      nameRe = "^[A-Za-z0-9_]{3,16}$";

      # The VT the couch session takes over. 7 is clear of GDM (1) and the GNOME
      # autologin session (2); getty@tty7 is conflicted out below.
      couchVt = 7;

      user = "sheath";
      home = config.users.users.${user}.home;
      # Prism's default data directory -- the one you actually open in the GUI.
      canonicalPrism = "${home}/.local/share/PrismLauncher";
      # Per-player data directories, materialized by minecraft-couch-sync.
      couchRoot = "${home}/.local/share/minecraft-couch";
      # The live roster. Sits beside the player directories it describes.
      rosterFile = "${couchRoot}/players.json";
      # The Prism instance ID every player launches. Must exist in the canonical
      # directory before the first launch (docs/minecraft.md step 1).
      instanceId = "couch";

      # ---------------------------------------------------------------------
      # Per-player Prism data directories. Idempotent; re-run after any mod change.
      # With no arguments it syncs every player in the roster; with arguments,
      # only those (which is how the menu materializes a newly added player).
      # ---------------------------------------------------------------------
      # Points the canonical instance's mods folder at the Nix-managed jar set. See
      # packages/minecraft-mods-link.nix; the same binary is in systemPackages on both
      # hosts via modules/minecraft-mods.nix.
      # The jar set, for its configDefaults (seeded per player below). The mods
      # themselves reach players through the symlink chain, not from here.
      clientMods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };

      modsLink = import ../packages/minecraft-mods-link.nix {
        inherit pkgs;
        prismRoot = canonicalPrism;
      };

      couchSync = pkgs.writeShellApplication {
        name = "minecraft-couch-sync";
        runtimeInputs = (with pkgs; [ coreutils rsync jq ]) ++ [ modsLink ];
        text = ''
          canon="${canonicalPrism}"
          root="${couchRoot}"
          inst="${instanceId}"
          roster="${rosterFile}"

          [ -d "$canon/instances/$inst" ] || {
            echo "minecraft-couch-sync: no Prism instance '$inst' in $canon." >&2
            echo "Create it in Prism first -- see docs/minecraft.md." >&2
            exit 1
          }

          mkdir -p "$root"

          # Re-point the canonical instance's mods at the current store path before
          # fanning out. Every player's mods is a symlink to this one, so doing it
          # here means a rebuild that changes the mod set reaches all of them on the
          # next sync -- there is no separate step to forget.
          minecraft-mods-link "$inst"

          # The game root is NOT always .minecraft: Prism 11 creates instances with a
          # plain "minecraft/" and only uses the dotted name for ones inherited from
          # MultiMC. Resolve it the way Prism does, or the excludes below silently
          # match nothing -- which would flatten each child's options.txt and config/
          # on every sync. packages/minecraft-mods-link.nix repeats this rule; keep
          # the two in step.
          if [ -d "$canon/instances/$inst/minecraft" ]; then
            mc="minecraft"
          else
            mc=".minecraft"
          fi

          if [ "$#" -gt 0 ]; then
            names=("$@")
          else
            [ -e "$roster" ] || {
              echo "minecraft-couch-sync: no roster at $roster yet." >&2
              echo "Start the couch launcher once to create it." >&2
              exit 1
            }
            mapfile -t names < <(jq -r '.players[]' "$roster")
          fi

          for name in "''${names[@]}"; do
            d="$root/$name"
            mkdir -p "$d/instances"

            # Big, read-mostly, identical for everyone: share one copy on disk.
            for shared in libraries meta assets java icons themes translations; do
              [ -e "$canon/$shared" ] || continue
              rm -rf "''${d:?}/$shared"
              ln -sfn "$canon/$shared" "$d/$shared"
            done

            # Launcher settings and the Microsoft account (which is what unlocks
            # offline launching at all): seed once, then leave each player's own.
            for f in prismlauncher.cfg accounts.json; do
              if [ -e "$canon/$f" ] && [ ! -e "$d/$f" ]; then
                cp "$canon/$f" "$d/$f"
              fi
            done

            # The instance itself. Excluded paths are per-player state that must
            # NOT be flattened by a re-sync: the mods folder is a symlink to the
            # canonical one -- which is itself a symlink into the store, so every
            # player picks up a mod list change from one rebuild -- and the
            # video/controller settings belong to each child.
            rsync -a --delete \
              --exclude "/$inst/$mc/mods" \
              --exclude "/$inst/$mc/saves" \
              --exclude "/$inst/$mc/options.txt" \
              --exclude "/$inst/$mc/config" \
              "$canon/instances/$inst" "$d/instances/"

            mkdir -p "$d/instances/$inst/$mc"
            ln -sfn "$canon/instances/$inst/$mc/mods" \
                    "$d/instances/$inst/$mc/mods"

            # Seed default mod configs into THIS player's config dir. config/ is
            # excluded from the rsync above because it is per-player state, so the
            # canonical instance's copy never reaches them -- without this the kids
            # would each get the mods' own defaults. Never overwrites: whatever a
            # child changes in Mod Menu is theirs. See configDefaults in
            # packages/minecraft-client-mods.nix.
            mkdir -p "$d/instances/$inst/$mc/config"
            for src in ${clientMods.configDefaults}/*; do
              [ -e "$src" ] || continue
              dst="$d/instances/$inst/$mc/config/$(basename "$src")"
              [ -e "$dst" ] || install -m0644 "$src" "$dst"
            done
          done

          echo "minecraft-couch-sync: ''${#names[@]} player director(ies) ready under $root"
        '';
      };

      # ---------------------------------------------------------------------
      # Layer 6: the pre-launcher.
      #
      # Pair/unpair controllers, add/remove players, decide who is holding which
      # pad, then hand a "<name>\t<event node>" list to the spawner.
      #
      # INPUT CODES ARE THE WHOLE DIFFICULTY HERE. The three Switch Pro pads go
      # through hid-nintendo and the Xbox Elite through xpadneo, and the two
      # drivers do not agree on how a D-pad is reported -- it may arrive as a hat
      # axis (ABS_HAT0X/Y) or as discrete buttons (BTN_DPAD_*), and this varies by
      # driver version too. Rather than guess, accept every plausible encoding:
      # any of them moves the cursor, and any OTHER button confirms. Being
      # permissive costs nothing and removes a class of "works on my pad" bug.
      #
      # There is deliberately NO back button: every screen carries a "Back" entry,
      # so only two gamepad actions ever need to work. `--probe` dumps raw events
      # so the codes can be checked against real hardware before a session with
      # four impatient children (docs/minecraft.md).
      # ---------------------------------------------------------------------
      couchMenu = pkgs.writers.writePython3Bin "minecraft-couch-menu"
        {
          libraries = [ pkgs.python3Packages.evdev ];
          # E501: UI strings read better than they wrap.
          flakeIgnore = [ "E501" ];
        }
        ''
          """Couch Minecraft pre-launcher: pads, players, then play."""
          import argparse
          import glob
          import json
          import os
          import re
          import select
          import subprocess
          import sys
          import termios
          import time
          import tty

          from evdev import InputDevice, categorize, ecodes

          SEED = [${lib.concatMapStringsSep ", " (n: "\"${n}\"") seedPlayers}]
          ROSTER = "${rosterFile}"
          SYNC = "${couchSync}/bin/minecraft-couch-sync"
          BLUETOOTHCTL = "${pkgs.bluez}/bin/bluetoothctl"
          NAME_RE = re.compile("${nameRe}")

          # D-pad button codes are excluded from "confirm" so a D-pad press can
          # never double as a selection. See the comment above the derivation.
          DPAD_BTNS = {ecodes.BTN_DPAD_UP, ecodes.BTN_DPAD_DOWN,
                       ecodes.BTN_DPAD_LEFT, ecodes.BTN_DPAD_RIGHT}
          DEADZONE = 16000

          KEYS_LOWER = ["abcdefghij", "klmnopqrst", "uvwxyz0123", "456789_"]
          SHIFT, BACKSPACE, ACCEPT = "SHIFT", "BACKSPACE", "OK"


          # -------------------------------------------------------------- roster

          def load_roster():
              """Read the roster, seeding it from Nix on first run."""
              if not os.path.exists(ROSTER):
                  os.makedirs(os.path.dirname(ROSTER), exist_ok=True)
                  save_roster(SEED)
                  return list(SEED)
              with open(ROSTER) as fh:
                  return list(json.load(fh).get("players", []))


          def save_roster(players):
              tmp = ROSTER + ".tmp"
              with open(tmp, "w") as fh:
                  json.dump({"players": players}, fh, indent=2)
                  fh.write("\n")
              os.replace(tmp, ROSTER)


          # ---------------------------------------------------------------- pads

          def pads():
              """Resolved event nodes for every joystick, de-duplicated.

              The udev rule tags one symlink per joystick node; resolving and
              de-duplicating guards against a pad that exposes several nodes
              (motion sensors, force feedback) being counted more than once.
              """
              seen = set()
              for link in sorted(glob.glob("/dev/input/couchpad-*")):
                  seen.add(os.path.realpath(link))
              return sorted(seen)


          # --------------------------------------------------------------- input

          class Input:
              """Merged keyboard + gamepad event source.

              Yields ("move", dx, dy), ("confirm",), ("text", ch),
              ("backspace",) or ("escape",). Both device classes drive every
              screen, which is what lets the menu be reached with no pad paired.
              """

              def __init__(self):
                  self.devices = []
                  for node in pads():
                      try:
                          self.devices.append(InputDevice(node))
                      except OSError:
                          pass
                  self.latched = {}
                  self.fd = sys.stdin.fileno()
                  self.saved = termios.tcgetattr(self.fd)
                  tty.setraw(self.fd)

              def close(self):
                  termios.tcsetattr(self.fd, termios.TCSADRAIN, self.saved)
                  for dev in self.devices:
                      dev.close()
                  self.devices = []

              def _from_pad(self, dev):
                  out = []
                  for event in dev.read():
                      if event.type == ecodes.EV_ABS:
                          horiz = event.code in (ecodes.ABS_HAT0X, ecodes.ABS_X)
                          vert = event.code in (ecodes.ABS_HAT0Y, ecodes.ABS_Y)
                          if not (horiz or vert):
                              continue
                          hat = event.code in (ecodes.ABS_HAT0X, ecodes.ABS_HAT0Y)
                          # A hat is already discrete; an analogue axis streams,
                          # so latch on the way out and re-arm at centre.
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


          # ------------------------------------------------------------ rendering

          def draw(title, lines, footer=""):
              out = ["\x1b[2J\x1b[H", "", "  " + title, ""]
              out += lines
              out += ["", "  " + footer if footer else ""]
              sys.stdout.write("\r\n".join(out))
              sys.stdout.flush()


          def menu(inp, title, options, footer="D-pad or arrows to move, any button or Enter to pick"):
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


          # ------------------------------------------------------------- text entry

          def type_name(inp, roster):
              """On-screen keyboard; the hardware keyboard types into it too."""
              text, shift, row, col = "", False, 0, 0
              while True:
                  rows = []
                  for r, chars in enumerate(KEYS_LOWER):
                      cells = []
                      for c, ch in enumerate(chars):
                          glyph = ch.upper() if shift else ch
                          cells.append("[%s]" % glyph if (r, c) == (row, col) else " %s " % glyph)
                      rows.append("     " + "".join(cells))
                  extras = [SHIFT, BACKSPACE, ACCEPT]
                  cells = []
                  for c, label in enumerate(extras):
                      cells.append("[%s]" % label if (row, col) == (len(KEYS_LOWER), c) else " %s " % label)
                  rows.append("     " + "".join(cells))
                  draw("New player name:  %s_" % text,
                       rows,
                       "3-16 letters, digits or _   |   or just type on the keyboard")

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
                      row = (row + dy) % (len(KEYS_LOWER) + 1)
                      width = len(extras) if row == len(KEYS_LOWER) else len(KEYS_LOWER[row])
                      col = (col + dx) % width
                      col = min(col, width - 1)
                      continue
                  if kind == "confirm":
                      if row == len(KEYS_LOWER):
                          label = extras[col]
                          if label == SHIFT:
                              shift = not shift
                          elif label == BACKSPACE:
                              text = text[:-1]
                          else:
                              err = validate(text, roster)
                              if err:
                                  message(inp, "Not a usable name", [err])
                              else:
                                  return text
                      else:
                          ch = KEYS_LOWER[row][col]
                          text += ch.upper() if shift else ch


          def validate(name, roster):
              if not NAME_RE.match(name):
                  return "Use 3-16 letters, digits or underscore. Minecraft rejects the rest."
              if name in roster:
                  return "%s is already on the list." % name
              return None


          # -------------------------------------------------------------- bluetooth

          def bt(*args, timeout=30):
              try:
                  done = subprocess.run([BLUETOOTHCTL] + list(args),
                                        capture_output=True, text=True, timeout=timeout)
                  return done.stdout + done.stderr
              except subprocess.TimeoutExpired:
                  return "timed out"


          def bt_list(kind):
              """(mac, name) pairs from `bluetoothctl devices [Paired]`."""
              out = []
              extra = ["Paired"] if kind == "paired" else []
              for line in bt("devices", *extra).splitlines():
                  parts = line.strip().split(" ", 2)
                  if len(parts) == 3 and parts[0] == "Device":
                      out.append((parts[1], parts[2]))
              return out


          def pair_screen(inp):
              draw("Pair a controller",
                   ["     Hold the pad's SYNC / PAIR button until its lights flash,",
                    "     then press any button or Enter to scan."],
                   "scanning takes about 10 seconds")
              while True:
                  action = inp.next()
                  if action[0] == "escape":
                      return
                  if action[0] == "confirm":
                      break

              draw("Pair a controller", ["     Scanning..."], "")
              known = {mac for mac, _ in bt_list("paired")}
              bt("--timeout", "10", "scan", "on", timeout=40)
              found = [(m, n) for m, n in bt_list("all") if m not in known]
              if not found:
                  message(inp, "Pair a controller",
                          ["Nothing new was found.",
                           "Make sure the pad is in pairing mode and try again."])
                  return

              options = ["%s  (%s)" % (n, m) for m, n in found] + ["Back"]
              pick = menu(inp, "Pair which controller?", options)
              if pick is None or pick == len(found):
                  return

              mac = found[pick][0]
              draw("Pair a controller", ["     Pairing %s..." % mac], "")
              log = bt("pair", mac) + bt("trust", mac) + bt("connect", mac)
              ok = "Connection successful" in log or "Pairing successful" in log
              if ok:
                  body = ["Paired and connected."]
              else:
                  body = ["That did not work. Output:"] + log.strip().splitlines()[-6:]
              message(inp, "Pair a controller", body)


          def unpair_screen(inp):
              paired = bt_list("paired")
              if not paired:
                  message(inp, "Unpair a controller", ["Nothing is paired."])
                  return
              options = ["%s  (%s)" % (n, m) for m, n in paired] + ["Back"]
              pick = menu(inp, "Unpair which controller?", options)
              if pick is None or pick == len(paired):
                  return
              mac = paired[pick][0]
              bt("remove", mac)
              message(inp, "Unpair a controller", ["Removed %s." % mac])


          # ---------------------------------------------------------------- players

          def add_player(inp, roster):
              name = type_name(inp, roster)
              if not name:
                  return roster
              roster = roster + [name]
              save_roster(roster)
              draw("Add a player", ["     Setting up %s..." % name], "")
              done = subprocess.run([SYNC, name], capture_output=True, text=True)
              if done.returncode != 0:
                  why = done.stderr.strip().splitlines() or ["(no output)"]
                  body = ["%s is on the list, but its game folder could not" % name,
                          "be created yet:", ""] + why
                  message(inp, "Add a player", body)
              else:
                  message(inp, "Add a player", ["%s is ready to play." % name])
              return roster


          def remove_player(inp, roster):
              if not roster:
                  message(inp, "Remove a player", ["Nobody on the list."])
                  return roster
              pick = menu(inp, "Remove which player?", roster + ["Back"])
              if pick is None or pick == len(roster):
                  return roster
              name = roster[pick]
              confirm = menu(inp, "Remove %s?" % name,
                             ["No, keep them", "Yes, remove"],
                             "this does NOT delete their character on the server")
              if confirm != 1:
                  return roster
              roster = [n for n in roster if n != name]
              save_roster(roster)
              message(inp, "Remove a player",
                      ["%s is off the list." % name,
                       "Their character is untouched -- adding the exact",
                       "same name back returns it."])
              return roster


          # ----------------------------------------------------------- assignment

          def assign(inp, roster):
              """Walk the pads; return [(name, node)]."""
              found = pads()
              if not found:
                  message(inp, "Start playing",
                          ["No controllers are connected.",
                           "Turn one on, or pair one from the main menu."])
                  return []
              if not roster:
                  message(inp, "Start playing", ["Nobody is on the player list yet."])
                  return []

              chosen, taken = [], set()
              for i, node in enumerate(found, start=1):
                  free = [n for n in roster if n not in taken]
                  if not free:
                      break
                  options = free + ["Nobody (sit out)", "Start now"]
                  pick = menu(inp, "Pad %d of %d -- who is this?" % (i, len(found)),
                              options,
                              "press a button ON THAT PAD, or use the keyboard")
                  if pick is None or pick == len(options) - 1:
                      break
                  if pick == len(options) - 2:
                      continue
                  taken.add(free[pick])
                  chosen.append((free[pick], node))
                  # A held button would otherwise carry into the next prompt.
                  time.sleep(0.4)
              return chosen


          # ---------------------------------------------------------------- probe

          def probe():
              found = pads()
              if not found:
                  sys.exit("no gamepads found -- are they paired and powered on?")
              dev = InputDevice(found[0])
              print("probing %s (%s)" % (found[0], dev.name))
              print("press the D-pad, the stick and the face buttons; Ctrl-C to stop")
              for event in dev.read_loop():
                  if event.type in (ecodes.EV_KEY, ecodes.EV_ABS):
                      print("  %s" % categorize(event))


          # ----------------------------------------------------------------- main

          def main():
              ap = argparse.ArgumentParser()
              ap.add_argument("--out", help="write <name>\\t<node> lines here")
              ap.add_argument("--probe", action="store_true",
                              help="dump raw events from one pad and exit")
              args = ap.parse_args()

              if args.probe:
                  probe()
                  return

              roster = load_roster()
              chosen = []
              inp = Input()
              try:
                  while True:
                      pick = menu(inp, "Minecraft -- couch",
                                  ["Start playing", "Add a player", "Remove a player",
                                   "Pair a controller", "Unpair a controller", "Quit"])
                      if pick in (None, 5):
                          break
                      if pick == 0:
                          chosen = assign(inp, roster)
                          if chosen:
                              break
                      elif pick == 1:
                          roster = add_player(inp, roster)
                      elif pick == 2:
                          roster = remove_player(inp, roster)
                      elif pick == 3:
                          pair_screen(inp)
                      elif pick == 4:
                          unpair_screen(inp)
              except KeyboardInterrupt:
                  chosen = []
              finally:
                  # Restore the terminal and, crucially, close every pad: SDL has
                  # to open them when the games start.
                  inp.close()

              sys.stdout.write("\x1b[2J\x1b[H")
              sys.stdout.flush()

              lines = "".join("%s\t%s\n" % (n, p) for n, p in chosen)
              if args.out:
                  with open(args.out, "w") as fh:
                      fh.write(lines)
              else:
                  sys.stdout.write(lines)


          main()
        '';

      # ---------------------------------------------------------------------
      # Layer 5: one client, one gamepad.
      # ---------------------------------------------------------------------
      couchPlayer = pkgs.writeShellApplication {
        name = "minecraft-couch-player";
        runtimeInputs = with pkgs; [ bubblewrap coreutils prismlauncher ];
        text = ''
          # usage: minecraft-couch-player <player name> <event node>
          name="''${1:?usage: minecraft-couch-player <name> <event node>}"
          node="''${2:?usage: minecraft-couch-player <name> <event node>}"

          if [ ! -e "$node" ]; then
            echo "minecraft-couch: $node is gone -- did the pad turn off?" >&2
            exit 1
          fi

          # The node handed over by the menu is already resolved. Binding the
          # RESOLVED node matters: SDL enumerates /dev/input/event*, so a sandbox
          # holding only a symlink would show the game no gamepad at all.
          node="$(readlink -f "$node")"

          # --dev-bind / /   : the sandbox is not a security boundary, only a
          #                    device-visibility one; the game needs the real
          #                    filesystem, GPU nodes and sockets.
          # --tmpfs /dev/input then re-bind: exactly one pad is visible.
          # --die-with-parent: exiting Hyprland tears every client down, so no
          #                    orphaned JVMs survive the session.
          exec bwrap \
            --dev-bind / / \
            --tmpfs /dev/input \
            --dev-bind "$node" "$node" \
            --die-with-parent \
            -- prismlauncher \
                 --dir ${couchRoot}/"$name" \
                 --launch ${instanceId} \
                 --offline "$name" \
                 --server 127.0.0.1:25565
        '';
      };

      # ---------------------------------------------------------------------
      # Layer 4: run the pre-launcher, then place the windows it asked for.
      # Hyprland's dwindle layout splits whichever window has focus, which yields
      # "left half + three stacked on the right" for four clients rather than
      # quadrants. Placing each window explicitly by address is deterministic and
      # independent of the order the JVMs happen to finish starting.
      # ---------------------------------------------------------------------
      couchSpawn = pkgs.writeShellApplication {
        name = "minecraft-couch-spawn";
        runtimeInputs = with pkgs; [ jq coreutils hyprland foot couchMenu couchPlayer ];
        excludeShellChecks = [ "SC2086" ];
        text = ''
          picks="$(mktemp -t minecraft-couch.XXXXXX)"
          trap 'rm -f "$picks"' EXIT

          # The menu is a TUI, so it needs a terminal. foot at a large font is
          # legible from the couch; --fullscreen keeps it off the tiling path.
          foot --fullscreen \
               --font "monospace:size=22" \
               --title "minecraft-couch-menu" \
               -- minecraft-couch-menu --out "$picks" || true

          if [ ! -s "$picks" ]; then
            # Nobody picked anything, or Quit. End the session quietly rather
            # than leaving a blank compositor on the projector.
            hyprctl dispatch exit
            exit 0
          fi

          total="$(wc -l < "$picks")"

          # Projector geometry, straight from the compositor -- no 1080p assumption.
          mon="$(hyprctl -j monitors)"
          sw="$(printf '%s' "$mon" | jq -r '.[0].width')"
          sh="$(printf '%s' "$mon" | jq -r '.[0].height')"
          hw=$(( sw / 2 )); hh=$(( sh / 2 ))

          # Quadrant (or half, or full) geometry for player $1 of $2, as "X Y W H".
          geometry() {
            case "$2" in
              1) echo "0 0 $sw $sh" ;;
              2) case "$1" in
                   1) echo "0 0 $sw $hh" ;;
                   *) echo "0 $hh $sw $hh" ;;
                 esac ;;
              *) case "$1" in
                   1) echo "0 0 $hw $hh" ;;
                   2) echo "$hw 0 $hw $hh" ;;
                   3) echo "0 $hh $hw $hh" ;;
                   *) echo "$hw $hh $hw $hh" ;;
                 esac ;;
            esac
          }

          # Addresses of mapped Minecraft windows. Prism's own launcher window (if
          # it ever shows) has class PrismLauncher and is filtered out here.
          mcWindows() {
            hyprctl -j clients | jq -r '.[] | select(.class | test("minecraft"; "i")) | .address'
          }

          # Block until a Minecraft window appears that we have not placed yet.
          # Cold start is JVM + asset load, so allow three minutes.
          awaitNewWindow() {
            local known="$1" addr
            for _ in $(seq 1 180); do
              for addr in $(mcWindows); do
                case " $known " in
                  *" $addr "*) ;;
                  *) printf '%s' "$addr"; return 0 ;;
                esac
              done
              sleep 1
            done
            return 1
          }

          placed=""
          i=0
          while IFS="$(printf '\t')" read -r name node; do
            [ -n "$name" ] || continue
            i=$(( i + 1 ))
            minecraft-couch-player "$name" "$node" &

            if ! addr="$(awaitNewWindow "$placed")"; then
              hyprctl notify 3 10000 0 "$name never opened a window"
              continue
            fi
            placed="$placed $addr"

            # shellcheck disable=SC2046
            set -- $(geometry "$i" "$total")
            hyprctl --batch "\
              dispatch setfloating address:$addr ; \
              dispatch resizewindowpixel exact $3 $4,address:$addr ; \
              dispatch movewindowpixel exact $1 $2,address:$addr"
          done < "$picks"

          # Keep the exec-once process alive so its children stay in the session's
          # control group; Hyprland exiting still kills the lot.
          wait
        '';
      };

      # ---------------------------------------------------------------------
      # Layer 3: the compositor config. Generated, never user state.
      # ---------------------------------------------------------------------
      hyprConf = pkgs.writeText "minecraft-couch-hyprland.conf" ''
        # Projector at its native mode, no scaling.
        monitor = , preferred, auto, 1

        # SDL's udev enumeration would still list the other players' event nodes
        # (they exist in /run/udev, just not in the sandbox's /dev/input) and log
        # a stream of open failures. Scan /dev/input directly instead.
        env = SDL_JOYSTICK_DISABLE_UDEV,1
        env = __GLX_VENDOR_LIBRARY_NAME,nvidia

        general {
          gaps_in = 0
          gaps_out = 0
          border_size = 0
          layout = dwindle
        }

        decoration {
          rounding = 0
          blur { enabled = false }
          shadow { enabled = false }
        }

        # An appliance for children: nothing that animates, dims, locks or blanks.
        animations { enabled = false }
        misc {
          disable_hyprland_logo = true
          disable_splash_rendering = true
          force_default_wallpaper = 0
          vfr = false
        }
        cursor {
          # Recommended on the proprietary NVIDIA driver.
          no_hardware_cursors = true
          inactive_timeout = 3
        }
        input {
          # Windows are placed by minecraft-couch-spawn; nothing should re-focus
          # because a stray mouse moved.
          follow_mouse = 0
        }

        # Grown-up escape hatches. Nothing here is needed for normal play.
        bind = SUPER SHIFT, Q, exit
        bind = SUPER, Tab, cyclenext

        exec-once = ${couchSpawn}/bin/minecraft-couch-spawn
      '';

      # The unit's ExecStart. Exports the per-session environment, then becomes
      # Hyprland so the compositor is PID 1 of the service cgroup and its exit
      # ends the session.
      couchSession = pkgs.writeShellApplication {
        name = "minecraft-couch-session";
        runtimeInputs = [ pkgs.hyprland ];
        text = ''
          # Do NOT let Hyprland push its variables into the user systemd manager.
          # That manager is shared with the GNOME autologin session, and
          # overwriting WAYLAND_DISPLAY there would break RustDesk's capture the
          # next time its user service restarts.
          export HYPRLAND_NO_SD_VARS=1

          exec Hyprland --config ${hyprConf}
        '';
      };

      # ---------------------------------------------------------------------
      # Layer 2 helpers: remember the VT we came from, and go back to it. Run with
      # a "+" prefix in the unit (i.e. as root) because chvt needs
      # CAP_SYS_TTY_CONFIG. Restoring happens in ExecStopPost so it also runs when
      # the session crashes -- otherwise a failure would strand the projector on a
      # blank tty7 with no way back to GNOME short of ssh.
      # ---------------------------------------------------------------------
      vtStash = "/run/minecraft-couch.prev-vt";
      enterVt = pkgs.writeShellScript "minecraft-couch-enter-vt" ''
        ${pkgs.kbd}/bin/fgconsole > ${vtStash} || echo 2 > ${vtStash}
        ${pkgs.kbd}/bin/chvt ${toString couchVt}
      '';
      leaveVt = pkgs.writeShellScript "minecraft-couch-leave-vt" ''
        prev="$(cat ${vtStash} 2>/dev/null || echo 2)"
        [ "$prev" = "${toString couchVt}" ] && prev=2
        ${pkgs.kbd}/bin/chvt "$prev" || true
        rm -f ${vtStash}
      '';

      # ---------------------------------------------------------------------
      # Layer 1: what the .desktop icon runs, inside the GNOME session.
      # ---------------------------------------------------------------------
      couchLauncher = pkgs.writeShellApplication {
        name = "minecraft-couch";
        runtimeInputs = with pkgs; [ systemd libnotify coreutils ];
        text = ''
          unit="minecraft-couch.service"
          # The setuid wrapper, NOT pkgs.sudo -- the nixpkgs binary is not setuid
          # and would fail with "must be owned by uid 0 and have the setuid bit set".
          sudo=/run/wrappers/bin/sudo

          fail() {
            notify-send -u critical "Minecraft" "$1" || true
            echo "minecraft-couch: $1" >&2
            exit 1
          }

          if ! systemctl is-active --quiet minecraft-server.service; then
            fail "The Minecraft server is not running. Try: sudo systemctl start minecraft-server"
          fi

          # Controllers and players are handled by the pre-launcher, so the only
          # thing worth checking here is the one piece Nix cannot create: the
          # Prism instance the whole thing launches.
          [ -d "${canonicalPrism}/instances/${instanceId}" ] || \
            fail "No Prism instance '${instanceId}' yet. See docs/minecraft.md."

          # Already running (someone clicked twice): just go to it.
          if systemctl is-active --quiet "$unit"; then
            exec "$sudo" ${pkgs.kbd}/bin/chvt ${toString couchVt}
          fi

          # --wait blocks until the session exits, so this process's lifetime
          # matches the play session and GNOME's "app is running" state is honest.
          # sheath has passwordless sudo (modules/core.nix), so no auth prompt
          # appears on the projector.
          exec "$sudo" systemctl start --wait "$unit"
        '';
      };

      desktopItem = pkgs.makeDesktopItem {
        name = "minecraft-couch";
        desktopName = "Minecraft (Couch)";
        comment = "Split-screen Minecraft on the projector";
        exec = "${couchLauncher}/bin/minecraft-couch";
        icon = "input-gaming";
        categories = [ "Game" ];
        terminal = false;
      };
    in
    {
      # In-kernel hid-nintendo drives the Switch Pro Controllers; the Xbox Elite
      # Series 2 needs xpadneo over Bluetooth. services.joycond stays OFF on
      # purpose: it republishes pads as virtual uinput devices, which would show
      # up alongside the real ones and make every pad appear twice in the
      # pre-launcher.
      hardware.xpadneo.enable = true;

      # One symlink per joystick node, so the pre-launcher can enumerate pads
      # without caring which is which -- players identify themselves instead.
      # ID_INPUT_JOYSTICK filters out the extra event nodes a pad may expose
      # (motion sensors, force feedback), which must not be offered as
      # controllers. %k is the kernel name, so the symlinks are unique and stable
      # for as long as a pad stays connected.
      # (udev has no trailing comments -- a "#" must begin the line.)
      services.udev.extraRules = lib.mkAfter ''
        SUBSYSTEM=="input", ENV{ID_INPUT_JOYSTICK}=="1", SYMLINK+="input/couchpad-%k"
      '';

      # The menu enforces this on names typed at runtime; catch a bad seed name
      # at build time rather than when a child cannot log in.
      assertions = [{
        assertion = lib.all (n: builtins.match "[A-Za-z0-9_]{3,16}" n != null) seedPlayers;
        message =
          "modules/minecraft-couch.nix: every seed player name must be 3-16 "
          + "characters of [A-Za-z0-9_]. Minecraft enforces this on the wire — "
          + "an over-long name cannot encode its login packet at all.";
      }];

      environment.systemPackages = [
        pkgs.prismlauncher
        couchLauncher
        couchSync
        couchMenu
        couchPlayer
        couchSpawn
        desktopItem
      ];

      # The couch session: a real logind session on its own VT.
      #
      # PAMName + TTYPath are the load-bearing pair -- they make pam_systemd
      # register a session bound to tty7, which is what lets Hyprland take DRM
      # master when that VT becomes active. Type=simple + Restart=no means the
      # unit's lifetime is exactly Hyprland's, and the control group takes every
      # JVM with it on exit (acceptance criterion: no orphaned processes).
      systemd.services.minecraft-couch = {
        description = "Couch Minecraft session";
        requires = [ "minecraft-server.service" ];
        after = [ "minecraft-server.service" "bluetooth.service" ];
        conflicts = [ "getty@tty${toString couchVt}.service" ];
        restartIfChanged = false;

        serviceConfig = {
          Type = "simple";
          User = user;
          Group = config.users.users.${user}.group;
          WorkingDirectory = home;

          PAMName = "login";
          TTYPath = "/dev/tty${toString couchVt}";
          TTYReset = true;
          TTYVHangup = true;
          TTYVTDisallocate = true;
          StandardInput = "tty-fail";
          StandardOutput = "journal";
          StandardError = "journal";
          UtmpIdentifier = "tty${toString couchVt}";
          UtmpMode = "user";

          # "+" runs these as root regardless of User= (chvt needs CAP_SYS_TTY_CONFIG).
          ExecStartPre = "+${enterVt}";
          ExecStart = "${couchSession}/bin/minecraft-couch-session";
          ExecStopPost = "+${leaveVt}";

          Restart = "no";
          TimeoutStopSec = 30;
        };
      };
    };
}
