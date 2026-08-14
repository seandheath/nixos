{ config, pkgs, lib, ... }:
# Couch Minecraft on hydrogen: 1-4 gamepads driving 1-4 tiled clients on the projector from
# one GNOME icon. Runbook in docs/minecraft.md. No setup step -- the game is a pinned Nix
# payload, so a fresh hydrogen boots straight into playable.
#
#   .desktop icon -> minecraft-couch            (inside the GNOME session)
#     -> systemd minecraft-couch.service        (a real login session on tty7)
#       -> Hyprland, generated config           (tiles; no bars, idle or lock)
#         -> minecraft-couch-spawn              (places N windows via hyprctl)
#           -> minecraft-couch-menu             (the pre-launcher)
#           -> minecraft-couch-player NAME NODE (bubblewrap: exactly one gamepad)
#             -> minecraft-client --name NAME --game-dir <per-player> -s 127.0.0.1
#
# A pre-launcher rather than pinned controllers, because keying seats to a pad's Bluetooth
# MAC made identity a property of the HARDWARE: pick up a sibling's pad and you were your
# sibling, and "2 players" always meant seats 1 and 2. Asking who is holding each pad makes
# pads interchangeable and the MAC question stop being asked. It also pairs controllers,
# since GNOME's Bluetooth panel is unreachable from tty7. Every screen takes keyboard as
# well as gamepad -- with no pad paired there is otherwise no way to reach the pairing
# screen.
#
# A separate VT rather than a nested compositor: GNOME must keep running for RustDesk
# capture, but Mutter cannot tile into quadrants, let a client position itself, or
# fullscreen a nested compositor. `PAMName=login` + `TTYPath` is what makes logind register
# a real session; without both, Hyprland cannot take DRM master.
#
# One game directory per player, holding only their options, mod config and screenshots --
# the jar, libraries and assets are one read-only store path every client shares.
#
# bubblewrap because evdev bypasses the display server, so by default every client sees
# every pad and all four characters move in unison.
{
  imports = [
    # The controllers are Bluetooth and hydrogen enables no stack of its own.
    ../modules/bluetooth.nix
  ];

  config =
    let
      # SEED ONLY: once rosterFile exists it is authoritative and this list is inert, so
      # editing these names later changes nothing. Add and remove players in the
      # pre-launcher; delete the JSON to re-seed. A merge would fight "Remove a player"
      # every time the menu started.
      #
      # RENAMING a player who has played orphans that character -- an offline UUID hashes
      # the username. Removing and re-adding the identical name is safe.
      seedPlayers = [
        "GentlemenPupil"
        "VizualWanderer"
        "PhantomSpecialst"
        "MadDreamer"
        "LuckyObserver" # sheath, when playing from the couch rather than sulfur
      ];

      # Enforced on the wire: an over-long name fails to encode its login packet.
      nameRe = "^[A-Za-z0-9_]{3,16}$";

      # Clear of GDM (1) and the autologin session (2); getty@tty7 is conflicted out below.
      couchVt = 7;

      user = "sheath";
      home = config.users.users.${user}.home;
      # Created on demand by minecraft-client; nothing to materialize in advance.
      couchRoot = "${home}/.local/share/minecraft-couch";
      rosterFile = "${couchRoot}/players.json";

      # The pre-launcher: pair/unpair pads, add/remove players, ask who holds which pad,
      # then hand "<name>\t<event node>" lines to the spawner.
      #
      # Input codes are the difficulty. hid-nintendo and xpadneo disagree on whether a D-pad
      # is a hat axis or discrete buttons, and it varies by driver version, so accept every
      # plausible encoding: any of them moves the cursor, any OTHER button confirms. No back
      # button -- every screen carries a Back entry, so only two actions must work.
      # `--probe` dumps raw events to check a new pad.
      couchMenu = pkgs.writers.writePython3Bin "minecraft-couch-menu"
        {
          # Propagates evdev, so this one entry covers both.
          libraries = [ pkgs.minecraft-menu ];
          # E501: UI strings read better than they wrap.
          flakeIgnore = [ "E501" ];
        }
        ''
          """Couch Minecraft pre-launcher: pads, players, then play."""
          import argparse
          import os
          import re
          import subprocess
          import sys
          import time

          from evdev import InputDevice, categorize, ecodes

          # The widgets moved to packages/minecraft-menu so the per-machine launcher
          # can use the same ones. Everything below is couch-only.
          from minecraft_menu import (
              Input,
              draw,
              load_json,
              menu,
              message,
              pads,
              save_json,
              type_text,
          )

          SEED = [${lib.concatMapStringsSep ", " (n: "\"${n}\"") seedPlayers}]
          ROSTER = "${rosterFile}"
          COUCH_ROOT = "${couchRoot}"
          BLUETOOTHCTL = "${pkgs.bluez}/bin/bluetoothctl"
          NAME_RE = re.compile("${nameRe}")


          # -------------------------------------------------------------- roster

          def load_roster():
              """Read the roster, seeding it from Nix on first run."""
              data = load_json(ROSTER, None)
              if data is None:
                  save_roster(SEED)
                  return list(SEED)
              return list(data.get("players", []))


          def save_roster(players):
              save_json(ROSTER, {"players": players})


          # ------------------------------------------------------------- text entry

          def type_name(inp, roster):
              """On-screen keyboard; the hardware keyboard types into it too."""
              return type_text(
                  inp,
                  "New player name:",
                  footer="3-16 letters, digits or _   |   or just type on the keyboard",
                  validate=lambda text: validate(text, roster),
              )


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
              # The game folder is just a directory: minecraft-client fills in the mods
              # symlink and the default mod configs on the first launch. Creating it
              # here only makes the failure (a read-only or full home) visible now
              # rather than to a child staring at a window that never opened.
              try:
                  os.makedirs(os.path.join(COUCH_ROOT, name), exist_ok=True)
              except OSError as exc:
                  message(inp, "Add a player",
                          ["%s is on the list, but its game folder could not" % name,
                           "be created:", "", str(exc)])
                  return roster
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
        runtimeInputs = (with pkgs; [ bubblewrap coreutils ])
          ++ [ config.services.minecraftClient.package ];
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
            -- minecraft-client \
                 --name "$name" \
                 --game-dir ${couchRoot}/"$name" \
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

          # From the compositor, so no 1080p assumption. FOCUSED, not .[0]: that is
          # aquamarine's enumeration order, and a mirror rule that fails to match would
          # silently reintroduce a second monitor. Falls back to .[0].
          mon="$(hyprctl -j monitors)"
          sw="$(printf '%s' "$mon" | jq -r 'map(select(.focused)) + . | .[0].width')"
          sh="$(printf '%s' "$mon" | jq -r 'map(select(.focused)) + . | .[0].height')"
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

          # Addresses of mapped Minecraft windows. The launcher is a CLI, so the only
          # windows on this compositor are the games themselves -- but match on the
          # class anyway rather than taking every window, because the menu's terminal
          # is still around when the first client maps.
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

          # When the last player exits, end the session so the projector returns to GNOME.
          # Minecraft's own "Quit Game" is the only exit a gamepad can reach, and without
          # this it left a black screen needing a keyboard. `wait` returns only once every
          # backgrounded player is gone, so three players are unaffected by the fourth
          # quitting.
          hyprctl dispatch exit
        '';
      };

      # The compositor config. Generated, never user state.
      hyprConf = pkgs.writeText "minecraft-couch-hyprland.conf" ''
        # ONE LOGICAL SCREEN: every external output mirrors the panel rather than extending
        # it. GNOME's display settings cannot deliver this -- the couch session is a
        # separate compositor on tty7 that never sees them -- and a catch-all monitor rule
        # would place a new output beside the panel, giving the spawner two monitors to
        # choose between. All three DP connectors are listed because the projector's cable
        # can land on any of them; an unplugged connector costs nothing.
        monitor = eDP-1, preferred, auto, 1
        monitor = DP-1, preferred, auto, 1, mirror, eDP-1
        monitor = DP-2, preferred, auto, 1, mirror, eDP-1
        monitor = DP-3, preferred, auto, 1, mirror, eDP-1

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

        # Nested categories must be written out. Hyprland's parser does not accept
        # a category opened and closed on one line -- `blur { enabled = false }`
        # is read as an option named "blur { enabled", which it rejects. Written
        # that way these three silently did nothing: blur, shadows and animations
        # were all still on, and the session drew an error banner across the top
        # of the screen on every launch.
        decoration {
          rounding = 0
          blur {
            enabled = false
          }
          shadow {
            enabled = false
          }
        }

        # An appliance for children: nothing that animates, dims, locks or blanks.
        animations {
          enabled = false
        }
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

          # Nothing else is worth checking. Controllers and players are the
          # pre-launcher's business, and the game itself is a store path that either
          # built or the host did not switch -- there is no hand-created instance left
          # to be missing, which is the whole point of the payload being in Nix.

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
      assertions = [
        {
          assertion = lib.all (n: builtins.match "[A-Za-z0-9_]{3,16}" n != null) seedPlayers;
          message =
            "modules/minecraft-couch.nix: every seed player name must be 3-16 "
            + "characters of [A-Za-z0-9_]. Minecraft enforces this on the wire — "
            + "an over-long name cannot encode its login packet at all.";
        }
        {
          # couchPlayer runs config.services.minecraftClient.package, which is only
          # meaningful once that module is enabled. Without this the failure is a
          # per-player launcher that is silently the wrong build.
          assertion = config.services.minecraftClient.enable;
          message =
            "modules/minecraft-couch.nix needs services.minecraftClient.enable "
            + "(modules/minecraft-client.nix) -- that is what provides the game.";
        }
      ];

      environment.systemPackages = [
        couchLauncher
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
