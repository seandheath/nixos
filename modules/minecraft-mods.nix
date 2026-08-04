{
  config,
  pkgs,
  lib,
  ...
}:
# Ships minecraft-mods-link on any host with a Minecraft client, keeps the configured
# Prism instances pointing at the current jar set, and guards the one invariant that
# spans the server and the clients: their Minecraft versions match.
#
# Imported by hosts/hydrogen.nix (couch clients) and hosts/sulfur.nix (desktop client).
# The jar list itself is packages/minecraft-client-mods.nix; see docs/minecraft.md.
let
  cfg = config.services.minecraftClientMods;
  clientMods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };
  user = "sheath";
  prismRoot = "${config.users.users.${user}.home}/.local/share/PrismLauncher";
  modsLink = import ../packages/minecraft-mods-link.nix { inherit pkgs prismRoot; };
in
{
  options.services.minecraftClientMods.instances = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "couch" ];
    description = ''
      Prism instance names whose mods folder is kept pointing at the Nix-managed jar
      set. Re-linked on boot and on any switch that changes the set. Instances that do
      not exist yet are skipped, not treated as an error.
    '';
  };

  config = {
    environment.systemPackages = [ modsLink ];

    # Re-link automatically. The store path is baked into ExecStart, so changing the
    # mod list changes the unit and switch-to-configuration restarts it -- which is
    # the whole point: a rebuild that adds a mod used to leave both machines silently
    # stale until someone remembered to run the command by hand.
    #
    # Type=oneshot + RemainAfterExit so it is "active" after a successful run and
    # therefore actually gets restarted on change. --if-present so a host whose Prism
    # instance does not exist yet reports a skip instead of failing the switch.
    #
    # This does NOT catch a newly created instance under an otherwise unchanged
    # configuration -- nothing changed, so nothing restarts. Run the command by hand
    # once after creating an instance (docs/minecraft.md), or
    # `systemctl restart minecraft-mods-link`.
    systemd.services.minecraft-mods-link = lib.mkIf (cfg.instances != [ ]) {
      description = "Point Prism instances' mods folders at the Nix-managed jar set";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Runs as the owner of the instances, not root: everything it touches is under
        # that user's home, and a root-created symlink there would be a nuisance.
        User = user;
        Group = config.users.users.${user}.group;
        ExecStart = map (
          inst: "${modsLink}/bin/minecraft-mods-link --if-present ${lib.escapeShellArg inst}"
        ) cfg.instances;
      };
    };

    # Only meaningful where the server actually is. sulfur has no minecraft-server to
    # compare against, but it consumes the same jar list, so hydrogen failing to build
    # is enough to catch the drift for both.
    #
    # The failure this prevents: a nixpkgs bump moves minecraft-server past 1.21.10
    # while the pinned Modrinth jars stay put. Without this the build succeeds and the
    # symptom is four children staring at an incompatible-mod screen.
    assertions = lib.optionals config.services.minecraft-server.enable [
      {
        assertion = pkgs.minecraft-server.version == clientMods.mcVersion;
        message = ''
          Minecraft version drift: the server is ${pkgs.minecraft-server.version} but the
          client mods in packages/minecraft-client-mods.nix are pinned to ${clientMods.mcVersion}.

          Re-pin every jar in that file to the new version (the header has the Modrinth
          query and the hash-conversion one-liner), then bump mcVersion. Check upstream
          support first -- not every mod tracks a point release promptly.
        '';
      }
    ];
  };
}
