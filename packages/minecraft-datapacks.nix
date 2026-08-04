{ pkgs }:
# Vanilla Tweaks datapacks for hydrogen's Minecraft world (see docs/minecraft.md).
#
# These are DATAPACKS, not mods: vanilla data-driven content the server loads out of
# world/datapacks. There is no mod loader involved and nothing is required of a
# client, which is what keeps modules/minecraft-server.nix's "a phone joining over
# the tunnel needs no install" guarantee true.
#
# WHY THE ZIPS ARE VENDORED RATHER THAN FETCHED. vanillatweaks.net builds a bundle
# per request and hands back a single-use URL: POSTing the identical selection twice
# returned VanillaTweaks_d377131_UNZIP_ME.zip and then VanillaTweaks_d860034_UNZIP_ME.zip.
# There is no stable per-pack URL to give fetchurl, and a link that 404s later would
# break hydrogen's nightly auto-update (modules/auto-update.nix), so the four zips are
# committed instead. 146 KB total.
#
# TO REGENERATE (after a Minecraft version bump, or to pick up upstream pack fixes):
#
#   curl -X POST https://vanillatweaks.net/assets/server/zipdatapacks.php \
#     --data-urlencode 'version=1.21' \
#     --data-urlencode 'packs={"convenience":["multiplayer sleep","unlock all recipes"],
#                              "gameplay":["graves"],"informative":["coordinates hud"]}'
#
# ...then download the returned link and unpack its four inner zips over
# packages/minecraft-datapacks/, keeping the vt-*.zip names (minecraft-server.nix
# prunes exactly that glob, so a rename would orphan the old copy in the world).
#
# VERSION WINDOW. Every pack here declares supported_formats 48-94, i.e. MC 1.21
# through 1.21.11. The server is pinned at 1.21.10. Nothing in Nix checks this --
# a server past 1.21.11 will simply log the packs as incompatible and skip them.
pkgs.runCommand "minecraft-datapacks-vanillatweaks"
  {
    # Recorded for the next person diffing against vanillatweaks.net; the zips
    # themselves carry the version in pack.mcmeta's description, not the filename.
    passthru.packVersions = {
      coordinates-hud = "1.2.16";
      graves = "4.0.6";
      multiplayer-sleep = "2.6.15";
      unlock-all-recipes = "2.0.16";
    };
  }
  ''
    mkdir -p "$out"
    cp ${./minecraft-datapacks}/vt-*.zip "$out"/
  ''
