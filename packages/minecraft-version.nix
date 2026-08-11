# THE Minecraft version for the whole fleet, and the vanilla server jar that goes with
# it. One file, so the number cannot be a property of whichever nixpkgs a host happens
# to build from.
#
# WHY THIS IS NOT JUST `pkgs.minecraft-server.version`. Since 2026-08-11 hydrogen is on
# nixos-26.05 and the five laptops are on nixos-unstable (see mkHost in flake.nix). The
# server jar therefore comes from a different channel than every client that connects
# to it, and the assertion that used to catch drift lived behind
# `config.services.minecraft-server.enable` -- true only on hydrogen. Left that way, an
# unstable bump could move the laptops' half of the stack while the only host able to
# notice was on a branch that had not moved.
#
# HOLD AT 1.21.10 (2026-08-10). nixpkgs 26.05 ships 1.21.11, but items 2-4 of the
# VERSION LOCKSTEP in modules/minecraft-server.nix -- Fabric intermediary mappings, the
# Modrinth mod pins and the client payload -- are all still 1.21.10, so the assertions
# correctly refuse to build. Pinning the jar keeps all five in step and makes the
# 1.21.11 migration a deliberate change rather than a side effect of a channel bump;
# nixpkgs no longer carries a per-patch attribute for 1.21.10
# (minecraftServers.vanilla-1-21 is the 1.21.11 build), hence the explicit src.
#
# Mojang serves old server jars indefinitely from piston-data; url and sha1 are
# transcribed from nixpkgs 25.11's minecraft-servers/versions.json. Java is unchanged
# (21) between the two releases, so the inherited wrapper is correct.
#
# TO MOVE THE STACK: change `version` here, re-run packages/minecraft-client/update.sh,
# re-pin packages/minecraft-client-mods.nix and packages/fabric-server.nix, and update
# the url/sha1 below from Mojang's version manifest. The assertions will tell you which
# of the five you forgot.
{
  version = "1.21.10";

  # Vanilla dedicated server jar for `version`.
  url = "https://piston-data.mojang.com/v1/objects/95495a7f485eedd84ce928cef5e223b757d2f764/server.jar";
  sha1 = "95495a7f485eedd84ce928cef5e223b757d2f764";
}
