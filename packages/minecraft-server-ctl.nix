{ pkgs }:

# Lifecycle for the on-demand Minecraft servers: one rootless podman container per server,
# one world directory each. The launcher drives this locally, and hydrogen exposes the same
# script over SSH behind a forced command (modules/minecraft-servers.nix), so both
# transports run identical code.
#
# Rootless, with no --userns=keep-id: container root maps to the invoking user, so a plain
# bind mount of the world directory needs no `,U` chown and the files land owned by that
# user. Verified against the real image.
let
  image = import ./minecraft-server-image.nix { inherit pkgs; };
  mcPin = import ./minecraft-version.nix;

  portMin = 25566;
  portMax = 25575;
in
pkgs.writeShellApplication {
  name = "minecraft-server-ctl";

  runtimeInputs = with pkgs; [
    podman
    coreutils
    gnugrep
    gnused
    gawk
  ];

  text = ''
    tag="${mcPin.version}"
    imageRef="localhost/minecraft-server:''${tag}"
    portMin=${toString portMin}
    portMax=${toString portMax}

    # hydrogen points this at /var/lib/minecraft-servers; locally it is under XDG.
    root="''${MC_SERVERS_ROOT:-''${XDG_DATA_HOME:-$HOME/.local/share}/minecraft/servers}"

    die() { echo "minecraft-server-ctl: $*" >&2; exit 1; }

    # podman names must match [a-zA-Z0-9][a-zA-Z0-9_.-]* -- same constraint as
    # modules/re-container.nix. Refuse rather than silently mangle, so the name the operator
    # sees in the launcher is the name podman has.
    check_name() {
      [ -n "''${1:-}" ] || die "a server name is required"
      case "$1" in
        [a-zA-Z0-9]*) ;;
        *) die "name must start with a letter or digit: $1" ;;
      esac
      case "$1" in
        *[!a-zA-Z0-9_.-]*) die "name may only contain letters, digits, _ . and -: $1" ;;
      esac
      [ "''${#1}" -le 32 ] || die "name is longer than 32 characters"
    }

    ctr() { echo "mc-$1"; }

    # The image is a store path, so this is a load from disk, never a registry pull.
    ensure_image() {
      podman image exists "$imageRef" || podman load -i ${image} >/dev/null
    }

    port_of() {
      podman inspect --format '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostPort}}{{end}}{{end}}' \
        "$(ctr "$1")" 2>/dev/null | head -1
    }

    used_ports() {
      for c in $(podman ps -a --filter 'name=^mc-' --format '{{.Names}}'); do
        podman inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostPort}}{{end}}{{end}}' "$c" 2>/dev/null
      done
    }

    free_port() {
      local taken p
      taken="$(used_ports | tr '\n' ' ')"
      for p in $(seq "$portMin" "$portMax"); do
        case " $taken " in *" $p "*) continue ;; esac
        echo "$p"; return 0
      done
      die "no free port in $portMin-$portMax; remove a server first"
    }

    rcon() {
      local name="$1"; shift
      local pw
      pw="$(cat "$root/$name/rcon.password" 2>/dev/null)" || die "no rcon password for $name"
      podman exec "$(ctr "$name")" mcrcon -H 127.0.0.1 -P 25575 -p "$pw" "$@"
    }

    cmd_list() {
      # Tab-separated: name, state, port. Parsed by the launcher.
      for c in $(podman ps -a --filter 'name=^mc-' --format '{{.Names}}' | sort); do
        local n st
        n="''${c#mc-}"
        st="$(podman inspect --format '{{.State.Status}}' "$c" 2>/dev/null || echo unknown)"
        printf '%s\t%s\t%s\n' "$n" "$st" "$(port_of "$n")"
      done
    }

    cmd_create() {
      local name="$1" port="''${2:-}"
      check_name "$name"
      # `exists && die` would take the whole script down under set -e on the common path,
      # where the container legitimately does not exist yet.
      if podman container exists "$(ctr "$name")"; then die "$name already exists"; fi
      [ -n "$port" ] || port="$(free_port)"
      ensure_image

      mkdir -p "$root/$name"
      # Reached only through `podman exec`, so it never crosses the container boundary;
      # generated per server anyway so one leaking cannot control another.
      if [ ! -e "$root/$name/rcon.password" ]; then
        # od reads a bounded amount, so nothing downstream closes the pipe early. The
        # obvious `tr -dc ... < /dev/urandom | head -c 32` dies of SIGPIPE under pipefail.
        ( umask 077; od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$root/$name/rcon.password" )
      fi

      podman run -d --name "$(ctr "$name")" \
        --restart=no \
        -p "127.0.0.1:$port:25565" \
        -v "$root/$name:/data:rw" \
        -e "MC_RCON_PASSWORD=$(cat "$root/$name/rcon.password")" \
        -e "MC_MOTD=$name" \
        --cap-drop=ALL \
        --security-opt no-new-privileges:true \
        "$imageRef" >/dev/null
      echo "$port"
    }

    cmd_start() {
      local name="$1"
      check_name "$name"
      podman container exists "$(ctr "$name")" || die "no such server: $name"
      ensure_image
      podman start "$(ctr "$name")" >/dev/null
      port_of "$name"
    }

    cmd_stop() {
      local name="$1"
      check_name "$name"
      podman container exists "$(ctr "$name")" || die "no such server: $name"
      if [ "$(podman inspect --format '{{.State.Status}}' "$(ctr "$name")")" = running ]; then
        # Ask the server to save and exit itself. Best effort: RCON is not up yet on a
        # server still generating its world, which is exactly when stop gets called by a
        # frustrated operator.
        rcon "$name" save-all stop >/dev/null 2>&1 || true
        # Bounded, and it is the backstop for the case above. `podman wait` was here and
        # blocked forever when RCON had not answered, because nothing had asked the
        # server to exit. SIGTERM makes Minecraft save and shut down cleanly by itself.
        podman stop -t 60 "$(ctr "$name")" >/dev/null 2>&1 || true
      fi
      echo stopped
    }

    # Readiness, and the reason it is not a TCP connect: rootless podman's port forwarder
    # accepts connections on the published port immediately, long before the server is
    # listening behind it. Measured at 5s against a server that took 90s to come up. RCON
    # answers only once the server is actually running.
    cmd_wait() {
      local name="$1" timeout="''${2:-300}" waited=0
      check_name "$name"
      while [ "$waited" -lt "$timeout" ]; do
        if rcon "$name" list >/dev/null 2>&1; then echo ready; return 0; fi
        if [ "$(podman inspect --format '{{.State.Status}}' "$(ctr "$name")" 2>/dev/null)" != running ]; then
          die "$name exited while starting; try: minecraft-server-ctl logs $name"
        fi
        sleep 3
        waited=$(( waited + 3 ))
      done
      die "$name was not ready within ''${timeout}s"
    }

    cmd_status() {
      local name="$1"
      check_name "$name"
      podman container exists "$(ctr "$name")" || { echo absent; return 0; }
      printf '%s\t%s\n' "$(podman inspect --format '{{.State.Status}}' "$(ctr "$name")")" "$(port_of "$name")"
    }

    cmd_logs() {
      local name="$1"
      check_name "$name"
      podman logs --tail "''${2:-40}" "$(ctr "$name")" 2>&1
    }

    # Removes the container, never the world. Recreating with the same name reuses it.
    cmd_remove() {
      local name="$1"
      check_name "$name"
      cmd_stop "$name" >/dev/null 2>&1 || true
      podman rm -f "$(ctr "$name")" >/dev/null 2>&1 || true
      echo "removed (world kept at $root/$name)"
    }

    running_servers() {
      for c in $(podman ps --filter 'name=^mc-' --format '{{.Names}}'); do
        echo "''${c#mc-}"
      done
    }

    # Bracket a backup. Minecraft writes region files continuously, so an archive taken
    # live can catch a half-written chunk -- the same reason modules/backup.nix flushes the
    # shared world through its console FIFO. Never fails: a world that cannot be reached is
    # worse left running than it is worth aborting a backup for.
    cmd_freeze() {
      local n
      for n in $(running_servers); do
        rcon "$n" save-off >/dev/null 2>&1 || true
        rcon "$n" save-all flush >/dev/null 2>&1 || true
      done
      echo frozen
    }

    cmd_thaw() {
      local n
      for n in $(running_servers); do
        rcon "$n" save-on >/dev/null 2>&1 || true
      done
      echo thawed
    }

    usage() {
      cat <<'USAGE'
    usage: minecraft-server-ctl SUBCOMMAND [ARGS]

      list                     name, state and port of every server, tab separated
      create NAME [PORT]       create and start; prints the port
      start NAME               start an existing one; prints the port
      wait NAME [TIMEOUT]      block until the server answers RCON
      stop NAME                save and stop
      status NAME              state and port, or "absent"
      logs NAME [LINES]        recent output
      remove NAME              remove the container, keep the world
      freeze                   suspend autosave on every running server, before a backup
      thaw                     resume autosave everywhere
    USAGE
    }

    sub="''${1:-}"
    if [ $# -gt 0 ]; then shift; fi
    case "$sub" in
      list)   cmd_list ;;
      create) cmd_create "''${1:-}" "''${2:-}" ;;
      start)  cmd_start "''${1:-}" ;;
      wait)   cmd_wait "''${1:-}" "''${2:-300}" ;;
      stop)   cmd_stop "''${1:-}" ;;
      status) cmd_status "''${1:-}" ;;
      logs)   cmd_logs "''${1:-}" "''${2:-40}" ;;
      remove) cmd_remove "''${1:-}" ;;
      freeze) cmd_freeze ;;
      thaw)   cmd_thaw ;;
      ""|-h|--help) usage ;;
      *) usage; die "unknown subcommand: $sub" ;;
    esac
  '';

  meta.description = "Create and control on-demand Minecraft servers in rootless podman";
}
