{
  config,
  pkgs,
  lib,
  ...
}:
# Ships minecraft-mods-link on any host with a Minecraft client, and guards the one
# invariant that spans the server and the clients: their Minecraft versions match.
#
# Imported by hosts/hydrogen.nix (couch clients) and hosts/sulfur.nix (desktop client).
# The jar list itself is packages/minecraft-client-mods.nix; see docs/minecraft.md.
let
  clientMods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };
  prismRoot = "${config.users.users.sheath.home}/.local/share/PrismLauncher";
  modsLink = import ../packages/minecraft-mods-link.nix { inherit pkgs prismRoot; };
in
{
  environment.systemPackages = [ modsLink ];

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
}
