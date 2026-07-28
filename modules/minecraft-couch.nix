{ config, pkgs, lib, ... }:
# Couch Minecraft on hydrogen: 1-4 Bluetooth gamepads driving 1-4 tiled Minecraft
# clients on the projector, launched from a GNOME icon. Full runbook (creating the
# Prism instance, installing mods, collecting controller MACs) is docs/minecraft.md.
#
# ARCHITECTURE, and why each layer exists:
#
#   .desktop icon  ->  minecraft-couch N        (runs inside the GNOME session)
#     -> systemd  minecraft-couch@N.service     (a REAL login session on tty7)
#       -> Hyprland with a generated config     (tiles; no bars, no idle, no lock)
#         -> minecraft-couch-spawn              (places N windows via hyprctl)
#           -> minecraft-couch-player i         (bubblewrap: exactly one gamepad)
#             -> prismlauncher -d <per-player data dir> -s 127.0.0.1:25565
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
# WHY FOUR PRISM DATA DIRS. Prism refuses to run twice, keyed on
# ApplicationId::fromPathAndVersion(dataPath, version) -- a second
# `prismlauncher --launch` would just message the first process, which would then
# spawn the game OUTSIDE the second sandbox and every character would move in
# unison. Distinct `-d` directories give distinct application IDs. They are not
# four copies: minecraft-couch-sync symlinks the heavy shared trees (and the mods
# folder) back to the canonical install, so mods are still installed once, in the
# GUI, in one place.
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
      # Players. EDIT THIS: replace the placeholder MACs with the real ones from
      # `bluetoothctl devices`, and the names with the kids' names. The names are
      # load-bearing -- an offline UUID is a hash of the username, so renaming a
      # player after they have played orphans that character's inventory,
      # advancements and ender chest.
      # ---------------------------------------------------------------------
      placeholderMac = "00:00:00:00:00:00";
      players = [
        { name = "Player1"; mac = placeholderMac; comment = "Switch Pro #1"; }
        { name = "Player2"; mac = placeholderMac; comment = "Switch Pro #2"; }
        { name = "Player3"; mac = placeholderMac; comment = "Switch Pro #3"; }
        { name = "Player4"; mac = placeholderMac; comment = "Xbox Elite Series 2"; }
      ];

      maxPlayers = builtins.length players;
      indices = lib.range 1 maxPlayers;
      playerAt = i: builtins.elemAt players (i - 1);

      # The VT the couch session takes over. 7 is clear of GDM (1) and the GNOME
      # autologin session (2); getty@tty7 is conflicted out below.
      couchVt = 7;

      user = "sheath";
      home = config.users.users.${user}.home;
      # Prism's default data directory -- the one you actually open in the GUI.
      canonicalPrism = "${home}/.local/share/PrismLauncher";
      # Per-player data directories, materialized by minecraft-couch-sync.
      couchRoot = "${home}/.local/share/minecraft-couch";
      # The Prism instance ID all four players launch. Must exist in the canonical
      # directory before the first launch (docs/minecraft.md step 1).
      instanceId = "couch";

      # ---------------------------------------------------------------------
      # Layer 5: one client, one gamepad.
      # ---------------------------------------------------------------------
      couchPlayer = pkgs.writeShellApplication {
        name = "minecraft-couch-player";
        runtimeInputs = with pkgs; [ bubblewrap coreutils prismlauncher ];
        text = ''
          # usage: minecraft-couch-player <1-${toString maxPlayers}>
          idx="''${1:?usage: minecraft-couch-player <player index>}"
          link="/dev/input/p''${idx}"

          # Offline usernames, baked in from Nix so there is exactly one place
          # they are defined. Changing one after that child has played orphans
          # their character (offline UUID = hash of the username).
          case "$idx" in
          ${lib.concatMapStringsSep "\n" (i:
            "  ${toString i}) name=${lib.escapeShellArg (playerAt i).name} ;;"
          ) indices}
            *) echo "minecraft-couch: no such player: $idx" >&2; exit 2 ;;
          esac

          # Resolve the udev symlink to the real event node. Binding the RESOLVED
          # node matters: SDL enumerates /dev/input/event*, so a sandbox holding
          # only "p1" would show the game no gamepad at all.
          if [ ! -e "$link" ]; then
            echo "minecraft-couch: $link is missing -- is controller $idx paired and on?" >&2
            exit 1
          fi
          node="$(readlink -f "$link")"

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
                 --dir "${couchRoot}/p''${idx}" \
                 --launch ${instanceId} \
                 --offline "$name" \
                 --server 127.0.0.1:25565
        '';
      };

      # ---------------------------------------------------------------------
      # Layer 4: window placement. Hyprland's dwindle layout splits whichever
      # window has focus, which yields "left half + three stacked on the right"
      # for four clients rather than quadrants. Placing each window explicitly by
      # address is deterministic and independent of the order the JVMs happen to
      # finish starting.
      # ---------------------------------------------------------------------
      couchSpawn = pkgs.writeShellApplication {
        name = "minecraft-couch-spawn";
        runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.hyprland couchPlayer ];
        excludeShellChecks = [ "SC2086" ];
        text = ''
          total="''${COUCH_PLAYERS:-1}"

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
          for i in $(seq 1 "$total"); do
            minecraft-couch-player "$i" &

            if ! addr="$(awaitNewWindow "$placed")"; then
              hyprctl notify 3 10000 0 "Player $i never opened a window"
              continue
            fi
            placed="$placed $addr"

            # shellcheck disable=SC2046
            set -- $(geometry "$i" "$total")
            hyprctl --batch "\
              dispatch setfloating address:$addr ; \
              dispatch resizewindowpixel exact $3 $4,address:$addr ; \
              dispatch movewindowpixel exact $1 $2,address:$addr"
          done

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
          COUCH_PLAYERS="''${1:?usage: minecraft-couch-session <player count>}"
          export COUCH_PLAYERS

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
      # Layer 1: what the .desktop icons run, inside the GNOME session.
      # ---------------------------------------------------------------------
      couchLauncher = pkgs.writeShellApplication {
        name = "minecraft-couch";
        runtimeInputs = with pkgs; [ systemd libnotify coreutils ];
        text = ''
          count="''${1:?usage: minecraft-couch <player count>}"
          unit="minecraft-couch@''${count}.service"
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

          for i in $(seq 1 "$count"); do
            [ -e "/dev/input/p''${i}" ] || fail "Controller $i is not connected. Turn it on and try again."
            [ -d "${couchRoot}/p''${i}" ] || fail "Player $i is not set up yet. Run: minecraft-couch-sync"
          done

          # Already running (someone clicked twice, or a second icon): just go to it.
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

      # ---------------------------------------------------------------------
      # Per-player Prism data directories. Idempotent; re-run after any mod change.
      # ---------------------------------------------------------------------
      couchSync = pkgs.writeShellApplication {
        name = "minecraft-couch-sync";
        runtimeInputs = with pkgs; [ coreutils rsync ];
        text = ''
          canon="${canonicalPrism}"
          root="${couchRoot}"
          inst="${instanceId}"

          [ -d "$canon/instances/$inst" ] || {
            echo "minecraft-couch-sync: no Prism instance '$inst' in $canon." >&2
            echo "Create it in Prism first -- see docs/minecraft.md." >&2
            exit 1
          }

          mkdir -p "$root"

          for i in ${lib.concatMapStringsSep " " toString indices}; do
            d="$root/p$i"
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
            # canonical one (install a mod once, all players get it), and the
            # video/controller settings belong to each child.
            rsync -a --delete \
              --exclude "/$inst/.minecraft/mods" \
              --exclude "/$inst/.minecraft/saves" \
              --exclude "/$inst/.minecraft/options.txt" \
              --exclude "/$inst/.minecraft/config" \
              "$canon/instances/$inst" "$d/instances/"

            mkdir -p "$d/instances/$inst/.minecraft"
            ln -sfn "$canon/instances/$inst/.minecraft/mods" \
                    "$d/instances/$inst/.minecraft/mods"
          done

          echo "minecraft-couch-sync: ${toString maxPlayers} player directories ready under $root"
        '';
      };

      desktopItems = map (i: pkgs.makeDesktopItem {
        name = "minecraft-couch-${toString i}";
        desktopName = "Minecraft — ${toString i} Player${lib.optionalString (i > 1) "s"}";
        comment = "Split-screen Minecraft on the projector";
        exec = "${couchLauncher}/bin/minecraft-couch ${toString i}";
        icon = "input-gaming";
        categories = [ "Game" ];
        terminal = false;
      }) indices;

      realMacs = lib.filter (p: p.mac != placeholderMac) players;
    in
    {
      # In-kernel hid-nintendo drives the Switch Pro Controllers; the Xbox Elite
      # Series 2 needs xpadneo over Bluetooth. services.joycond stays OFF on
      # purpose: it republishes pads as virtual uinput devices, which have no
      # ATTRS{uniq} and would defeat the MAC-keyed rules below.
      hardware.xpadneo.enable = true;

      # Stable player identity. Bluetooth event device numbers are handed out in
      # connection order, and three identical Switch Pro Controllers also collide
      # on by-id, so without this "player 1" would mean "whoever powered on
      # first". uniq is the pad's Bluetooth MAC. ID_INPUT_JOYSTICK filters out the
      # extra event nodes a pad may expose (motion sensors, force feedback).
      # (udev has no trailing comments -- a "#" must begin the line.)
      services.udev.extraRules = lib.mkAfter (lib.concatMapStringsSep "\n" (i:
        let p = playerAt i; in ''
          # player ${toString i}: ${p.comment} -> ${p.name}
          SUBSYSTEM=="input", ENV{ID_INPUT_JOYSTICK}=="1", ATTRS{uniq}=="${lib.toLower p.mac}", SYMLINK+="input/p${toString i}"''
      ) indices);

      # Placeholder MACs are a warning, not an assertion: the server half of this
      # deploy must still build and run while the controllers are being paired.
      warnings = lib.optional (realMacs == [ ])
        ("modules/minecraft-couch.nix still has placeholder controller MACs — "
         + "run `bluetoothctl devices` on hydrogen and fill them in, or "
         + "/dev/input/p1..p${toString maxPlayers} will never appear.");

      environment.systemPackages = [
        pkgs.prismlauncher
        couchLauncher
        couchSync
        couchPlayer
        couchSpawn
      ] ++ desktopItems;

      # The couch session: a real logind session on its own VT.
      #
      # PAMName + TTYPath are the load-bearing pair -- they make pam_systemd
      # register a session bound to tty7, which is what lets Hyprland take DRM
      # master when that VT becomes active. Type=simple + Restart=no means the
      # unit's lifetime is exactly Hyprland's, and the control group takes every
      # JVM with it on exit (acceptance criterion: no orphaned processes).
      systemd.services."minecraft-couch@" = {
        description = "Couch Minecraft session (%i player(s))";
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
          ExecStart = "${couchSession}/bin/minecraft-couch-session %i";
          ExecStopPost = "+${leaveVt}";

          Restart = "no";
          TimeoutStopSec = 30;
        };
      };
    };
}
