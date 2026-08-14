# THE Minecraft version for the whole fleet, and the vanilla jar that goes with it. One
# file, so the number is not a property of whichever nixpkgs a host builds from -- the
# assertions in modules/minecraft-client.nix compare against this on every host, not just
# the one running the server.
#
# HELD AT 1.21.10: nixpkgs ships newer, but the Fabric intermediary mappings, the Modrinth
# mod pins and the client payload are all still 1.21.10, so the assertions correctly refuse.
# Moving is a deliberate change, not a side effect of a channel bump. nixpkgs no longer
# carries a per-patch attribute for this version, hence the explicit src; Mojang serves old
# jars indefinitely from piston-data.
#
# TO MOVE THE STACK: change `version`, re-run packages/minecraft-client/update.sh, re-pin
# minecraft-client-mods.nix and fabric-server.nix, and update the url/sha1 below. The
# assertions name whichever of the five you forgot.
{
  version = "1.21.10";

  # Vanilla dedicated server jar for `version`.
  url = "https://piston-data.mojang.com/v1/objects/95495a7f485eedd84ce928cef5e223b757d2f764/server.jar";
  sha1 = "95495a7f485eedd84ce928cef5e223b757d2f764";
}
