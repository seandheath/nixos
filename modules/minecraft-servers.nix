{ config, lib, pkgs, ... }:

# Hydrogen-hosted on-demand Minecraft servers: one rootless podman container per world,
# created by the launcher over SSH.
#
# Separate from modules/minecraft-server.nix, which is the shared always-on world on 25565
# and stays exactly as it was. These are extra worlds, started when someone wants one.
#
# The control channel is SSH behind a forced command, so a key that leaks off a child's
# laptop can only manage Minecraft servers -- it is not a shell on the 24/7 box.
let
  cfg = config.fleet.minecraftServers;

  root = "/var/lib/minecraft-servers";

  # Whatever the key runs, this is what it gets. SSH_ORIGINAL_COMMAND is split into words
  # with globbing off, and only the control script's own subcommands are allowed through.
  sshEntry = pkgs.writeShellApplication {
    name = "minecraft-server-ctl-ssh";
    runtimeInputs = [ pkgs.minecraft-server-ctl ];
    text = ''
      export MC_SERVERS_ROOT=${root}

      set -f
      # Deliberate word splitting: the arguments arrive as one string.
      # shellcheck disable=SC2086
      set -- ''${SSH_ORIGINAL_COMMAND:-}

      case "''${1:-}" in
        list | worlds | create | start | wait | stop | status | logs | remove) ;;
        *)
          echo "refused: this key may only run minecraft-server-ctl subcommands" >&2
          exit 1
          ;;
      esac

      exec minecraft-server-ctl "$@"
    '';
  };
in
{
  options.fleet.minecraftServers = {
    enable = lib.mkEnableOption "on-demand Minecraft servers in rootless podman";

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA... gentlemenpupil" ];
      description = ''
        Public keys allowed to drive the control script. Each is forced to
        minecraft-server-ctl-ssh, so it grants no shell. Prefer one key per machine over
        one shared key, so a single laptop can be revoked on its own.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;

    # Rootless podman as a dedicated user, so a container escape lands on an account that
    # owns nothing but worlds. isNormalUser is what gives it subuid/subgid ranges
    # automatically; lingering is what keeps containers alive after the SSH session that
    # started them has gone.
    users.users.mcctl = {
      isNormalUser = true;
      # Fixed, because modules/backup.nix has to name /run/user/<uid> to reach this
      # user's rootless podman, and a dynamically allocated uid is null at eval time.
      uid = 1100;
      home = root;
      createHome = true;
      description = "On-demand Minecraft servers";
      linger = true;
      openssh.authorizedKeys.keys = map (
        key:
        "command=\"${lib.getExe sshEntry}\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ${key}"
      ) cfg.authorizedKeys;
    };
    users.groups.mcctl = { };

    environment.systemPackages = [ pkgs.minecraft-server-ctl ];

    # sheath drives the same script directly rather than through SSH; the worlds are
    # mcctl's, so the path has to be pointed at explicitly.
    environment.variables.MC_SERVERS_ROOT = lib.mkDefault root;

    assertions = [
      {
        assertion = cfg.authorizedKeys != [ ] -> config.services.openssh.enable;
        message = "fleet.minecraftServers.authorizedKeys needs services.openssh.enable.";
      }
    ];
  };
}
