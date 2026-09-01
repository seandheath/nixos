{ config, lib, pkgs, ... }:

# The pre-launcher for machines that are not the couch. Choose a player, choose a server,
# and it brings the server up before starting the game.
#
# Separate from services.minecraftClient, which stays exactly what it was: one baked-in
# name quick-playing into one baked-in server. That entry point is still the fastest way
# into the family world and the launcher does not replace it.
let
  cfg = config.services.minecraftLauncher;

  launcher = import ../packages/minecraft-launcher.nix {
    inherit pkgs;
    mcClient = config.services.minecraftClient.package;
    inherit (cfg) hydrogenHost;
    controlKeyFile = if cfg.controlKeyFile == null then "" else cfg.controlKeyFile;
    defaultPlayer =
      if config.services.minecraftClient.playerName == null
      then ""
      else config.services.minecraftClient.playerName;
    defaultServer =
      if config.services.minecraftClient.server == null
      then ""
      else config.services.minecraftClient.server;
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "minecraft-launcher";
    desktopName = "Minecraft (choose a world)";
    comment = "Pick a player and a server, then play";
    exec = lib.getExe launcher;
    icon = "input-gaming";
    terminal = true;
    categories = [ "Game" ];
  };
in
{
  options.services.minecraftLauncher = {
    enable = lib.mkEnableOption "the Minecraft pre-launcher";

    localServers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Allow servers that run on this machine, in rootless podman. Turning this off
        leaves only hydrogen-hosted and already-running servers, and skips enabling
        podman -- worth it on a machine that should never host a world.
      '';
    };

    hydrogenHost = lib.mkOption {
      type = lib.types.str;
      default = "mc.luckyobserver.com";
      description = ''
        Where "on hydrogen" servers are reached, and the SSH host the control channel
        talks to. Resolves through Headscale DNS and the home subnet route.
      '';
    };

    desktopEntry = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install a desktop entry. Wants a terminal, unlike the plain client.";
    };

    controlKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SOPS-managed SSH private key used only for Minecraft world control on hydrogen.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ launcher ] ++ lib.optional cfg.desktopEntry desktopItem;

    # The module supplies what it needs rather than asserting someone else did. mkDefault
    # so a host that already configures podman (sulfur, via modules/virtualisation.nix)
    # keeps its own settings.
    virtualisation.podman.enable = lib.mkIf cfg.localServers (lib.mkDefault true);

    assertions = [
      {
        assertion = config.services.minecraftClient.enable;
        message = ''
          services.minecraftLauncher.enable needs services.minecraftClient.enable: the
          launcher only chooses a name and a server, then execs minecraft-client, which
          owns the payload, the offline UUID and the game directory.
        '';
      }
    ];
  };
}
