{ pkgs, toolPkgs ? pkgs, defaultName ? null, defaultServer ? null }:
# minecraft-client -- start Minecraft from the pinned payload, offline, as a named player.
#
#   minecraft-client [--name NAME] [--game-dir DIR] [--server HOST[:PORT]] [-- ARGS...]
#
# The whole launcher: no GUI, no instance, no account, and no state Nix does not produce.
# What is left in the game directory afterwards is exactly what belongs to a player --
# options, mod configs, screenshots.
#
# portablemc rather than a bare `java -cp` because the classpath, argument list and the rule
# evaluation deciding which of the 115 libraries this platform wants are Mojang's business
# and change between releases; portablemc reads all of it out of the pinned metadata.
#
# It never touches the network: every file is already present at the right size, so nothing
# is scheduled for download, and --fetch-exclude-all removes the manifest re-validation that
# remained. Verify with an empty game dir in a network namespace:
#
#   unshare -rn minecraft-client --name X --game-dir /tmp/mc --offline -- --dry
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

    # The offline UUID as the game computes it: nameUUIDFromBytes("OfflinePlayer:<name>"),
    # an MD5 with the version and variant bits forced. The server derives this itself from
    # the name, so inventory follows the NAME regardless -- but portablemc's own offline
    # session would invent one from a private namespace, and passing the real one keeps
    # client-side identity consistent.
    hex="$(printf '%s' "OfflinePlayer:$name" | md5sum | cut -d' ' -f1)"
    b6=$(( 0x''${hex:12:2} & 0x0f | 0x30 ))
    b8=$(( 0x''${hex:16:2} & 0x3f | 0x80 ))
    # shellcheck disable=SC2059  # the format string is a literal; only the args vary.
    uuid="$(printf '%s%02x%s%02x%s' "''${hex:0:12}" "$b6" "''${hex:14:2}" "$b8" "''${hex:18}")"

    mkdir -p "$gameDir"

    # On every launch rather than from a unit: a unit only re-runs when the configuration
    # changes, which left a game directory created after the last rebuild silently unlinked.
    # Consequence, deliberate: mods/ is a read-only store path, so nothing can install a mod
    # at runtime. Add them in packages/minecraft-client-mods.nix.
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

    # --main-dir is the ONLY global option; everything else belongs to `start`.
    #
    # --mc-dir IS NOT OPTIONAL: it defaults to --main-dir, which is the read-only payload,
    # so leaving it off points the running game at /nix/store.
    #
    # NEITHER IS --bin-dir, whatever its help text says. 5.0.3 documents it as derived from
    # --mc-dir and then defaults it to <main-dir>/bin/; the second is the truth, so without
    # it the LWJGL natives extract into the store and fail read-only.
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
