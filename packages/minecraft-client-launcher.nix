{ pkgs, toolPkgs ? pkgs, defaultName ? null, defaultServer ? null }:
# toolPkgs supplies the two things the launcher RUNS (portablemc and the JVM), as
# opposed to the payload it runs them against. modules/minecraft-client.nix passes the
# stable nixpkgs here on every host, so these stay identical fleet-wide even though the
# laptops build from nixos-unstable -- see that module's comment for why.
# minecraft-client -- start Minecraft from the pinned payload, offline, as a named
# player.
#
#   minecraft-client [--name NAME] [--game-dir DIR] [--server HOST[:PORT]] [-- ARGS...]
#
# This is the whole launcher. There is no GUI, no instance to create, no account to log
# in to and no state that Nix does not produce: the game itself comes from
# packages/minecraft-client (every jar and asset pinned by hash), the mods from
# packages/minecraft-client-mods.nix, and portablemc turns the two into a JVM command
# line. What is left in the game directory afterwards is exactly the state that belongs
# to a player: their options, their mod configs, their screenshots.
#
# WHY portablemc AND NOT A BARE `java -cp`. The classpath, the argument list and the
# rule evaluation that decides which of the 115 libraries this platform actually wants
# are Mojang's business and they change between releases. portablemc reads all of that
# out of the pinned metadata; hand-transcribing it (as packages/fabric-server.nix does
# for the server, where it is a main class and eight jars) would mean re-deriving the
# client launch contract on every Minecraft bump.
#
# WHY IT NEVER TOUCHES THE NETWORK. Every file is already in the payload at the right
# size, so nothing is scheduled for download; --fetch-exclude-all then removes the one
# call that remained, portablemc's re-validation of the version metadata against Mojang's
# manifest. Verified with an empty game directory inside a network namespace:
#
#   unshare -rn minecraft-client --name X --game-dir /tmp/mc --offline -- --dry
#
# resolves fabric-loader-0.19.3-1.21.10 and the 1.21.10 it inherits from, verifies 78
# libraries and 4403 assets, loads the JVM, and exits 0.
#
# Under 4.x this was a weaker claim: the manifest fetch still happened and merely fell
# back to the local copy on failure, with --timeout bounding how long it could stall on a
# network that accepts connections but never answers. 5.x can decline to make the call at
# all, so the guarantee is now structural rather than a bounded wait.
#
# PORTABLEMC 5.x IS A RUST REWRITE. Comments here used to cite Python source locations;
# none of them survive, so what is recorded below is observed behaviour of 5.0.3 instead.
let
  client = import ./minecraft-client { inherit pkgs; };
  clientMods = import ./minecraft-client-mods.nix { inherit pkgs; };

  # Mojang states the major Java version per release; honour it rather than whatever
  # `java` happens to be on PATH. Passing --jvm explicitly also keeps 5.x's --jvm-policy
  # out of the picture, which can otherwise decide to go and fetch a JVM -- the one
  # remaining way a launch could reach for the network.
  jdk = toolPkgs."jdk${toString client.javaVersion}";
in
pkgs.writeShellApplication {
  name = "minecraft-client";

  runtimeInputs = [ pkgs.coreutils toolPkgs.portablemc ];

  text = ''
    payload="${client}"
    mods="${clientMods}"
    defaults="${clientMods.configDefaults}"
    version="${client.versionId}"

    name="''${MINECRAFT_USERNAME:-${if defaultName == null then "" else defaultName}}"
    gameDir=""
    server="${if defaultServer == null then "" else defaultServer}"

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name)     name="''${2:?--name needs a value}"; shift 2 ;;
        --game-dir) gameDir="''${2:?--game-dir needs a value}"; shift 2 ;;
        --server)   server="''${2:?--server needs a value}"; shift 2 ;;
        --offline)  server=""; shift ;;
        --)         shift; break ;;
        -h|--help)
          echo "usage: minecraft-client [--name NAME] [--game-dir DIR] [--server HOST[:PORT]]"
          echo "                        [--offline] [-- <extra portablemc start args>]"
          echo
          echo "  --offline   do not join a server; start at the main menu."
          echo "  Anything after -- is passed to \`portablemc start\` (--dry, --resolution WxH)."
          exit 0
          ;;
        *)
          echo "minecraft-client: unknown argument '$1' (pass extra portablemc args after --)" >&2
          exit 2
          ;;
      esac
    done

    if [ -z "$name" ]; then
      echo "minecraft-client: no player name. Pass --name, or set MINECRAFT_USERNAME." >&2
      exit 2
    fi

    # Minecraft enforces this on the wire: an over-long name cannot even encode its
    # login packet, so the client fails to connect with nothing useful in the log.
    # modules/minecraft-couch.nix applies the same rule to names typed at runtime.
    if ! printf '%s' "$name" | grep -qE '^[A-Za-z0-9_]{3,16}$'; then
      echo "minecraft-client: '$name' is not a valid Minecraft name (3-16 of [A-Za-z0-9_])." >&2
      exit 2
    fi

    : "''${gameDir:=''${XDG_DATA_HOME:-$HOME/.local/share}/minecraft/$name}"

    # ---------------------------------------------------------------------
    # The offline player UUID, computed the way the game does it:
    # UUID.nameUUIDFromBytes("OfflinePlayer:<name>") -- an MD5 digest with the version
    # (3) and variant (RFC 4122) bits forced.
    #
    # An offline-mode server derives this itself from the name it is given, so a
    # character's inventory follows the NAME whatever we send here. portablemc's own
    # offline session would invent a UUID from a private uuid5 namespace
    # of its own, which is nobody's idea of this player; passing the
    # real one keeps client-side identity (skin lookups, local worlds) consistent with
    # the server's.
    # ---------------------------------------------------------------------
    hex="$(printf '%s' "OfflinePlayer:$name" | md5sum | cut -d' ' -f1)"
    b6=$(( 0x''${hex:12:2} & 0x0f | 0x30 ))
    b8=$(( 0x''${hex:16:2} & 0x3f | 0x80 ))
    # shellcheck disable=SC2059  # the format string is a literal; only the args vary.
    uuid="$(printf '%s%02x%s%02x%s' "''${hex:0:12}" "$b6" "''${hex:14:2}" "$b8" "''${hex:18}")"

    mkdir -p "$gameDir"

    # ---------------------------------------------------------------------
    # Point this player's mods at the Nix-managed jar set and seed the mod configs.
    #
    # Done on every launch rather than from a systemd unit: a unit only re-runs when
    # something in the configuration changes, which used to leave a game directory
    # created after the last rebuild silently unlinked. Here there is no window --
    # whatever starts the game has already fixed it.
    #
    # CONSEQUENCE, deliberate: mods/ is a read-only store path, so nothing can install
    # a mod into it at runtime. That is the trade for one list driving both machines;
    # add mods in packages/minecraft-client-mods.nix instead.
    # ---------------------------------------------------------------------
    mkdir -p "$gameDir/config"
    for src in "$defaults"/*; do
      [ -e "$src" ] || continue
      dst="$gameDir/config/$(basename "$src")"
      if [ ! -e "$dst" ]; then
        install -m0644 "$src" "$dst"
        echo "minecraft-client: seeded config/$(basename "$src")"
      fi
    done

    target="$gameDir/mods"
    if [ "$(readlink "$target" 2>/dev/null || true)" != "$mods" ]; then
      if [ -L "$target" ]; then
        rm -f "$target"
      elif [ -d "$target" ]; then
        if [ -n "$(ls -A "$target")" ]; then
          # A real directory with jars in it -- mods installed by hand, or migrated
          # from a Prism instance. Never delete those silently; stash them once, using
          # the same .stateful convention the nixpkgs minecraft-server module uses when
          # it takes over server.properties.
          backup="$gameDir/mods.stateful"
          if [ -e "$backup" ]; then
            echo "minecraft-client: $target is a non-empty directory and $backup" >&2
            echo "already exists, so there is nowhere safe to stash it. Move or delete" >&2
            echo "one of them by hand, then re-run." >&2
            exit 1
          fi
          mv "$target" "$backup"
          echo "minecraft-client: stashed the previous mods/ at $backup"
        else
          rmdir "$target"
        fi
      fi
      ln -s "$mods" "$target"
      echo "minecraft-client: mods -> $mods"
    fi

    # HOST[:PORT] -- quick play connects straight to the server, so the children never
    # see a server list.
    connect=()
    if [ -n "$server" ]; then
      case "$server" in
        *:*) connect=(--join-server "''${server%:*}" --join-server-port "''${server##*:}") ;;
        *)   connect=(--join-server "$server") ;;
      esac
    fi

    # --main-dir is the ONLY global option here; everything else belongs to `start` and
    # portablemc rejects it before the subcommand. That split changed in 5.x, along with
    # three flag names -- see the header.
    #
    # --mc-dir IS NOT OPTIONAL. In 5.x it defaults to --main-dir, and --main-dir is the
    # read-only store payload, so leaving it off does not fall back to something harmless
    # -- it points the running game at /nix/store. It is what keeps this player's
    # options, saves and screenshots on writable disk.
    #
    # NEITHER IS --bin-dir, and its help text will tell you otherwise. 5.0.3 documents it
    # as "derived from the '--mc-dir' path", then gives the default as '<main-dir>/bin/'.
    # The second one is the truth: with only --mc-dir set, extracting the LWJGL natives
    # fails with
    #     create dir: /nix/store/...-minecraft-client-1.21.10/bin/fabric-loader-...
    #     I/O error: Read-only file system (os error 30)
    # which is the loud failure the payload is designed to produce, but a failure all the
    # same. Under 4.x the bin dir came off the work dir and this was free. Point it at the
    # game directory to restore that.
    exec portablemc \
      --main-dir "$payload" \
      start "$version" \
      --mc-dir "$gameDir" \
      --bin-dir "$gameDir/bin" \
      --fetch-exclude-all \
      --jvm ${pkgs.lib.getExe' jdk "java"} \
      -u "$name" -i "$uuid" \
      "''${connect[@]}" \
      "$@"
  '';

  meta = {
    description = "Offline Minecraft ${client.mcVersion} client (Fabric ${client.loaderVersion})";
    mainProgram = "minecraft-client";
    platforms = pkgs.lib.platforms.linux;
  };
}
