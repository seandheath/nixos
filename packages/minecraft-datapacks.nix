{ pkgs }:
# Vanilla Tweaks datapacks for hydrogen's world (docs/minecraft.md). DATAPACKS, not mods:
# vanilla data-driven content loaded from world/datapacks, with nothing required of a
# client -- which is what keeps the unmodded-join guarantee true.
#
# VENDORED RATHER THAN FETCHED: vanillatweaks.net builds a bundle per request and returns a
# single-use URL, so there is nothing stable for fetchurl and a later 404 would break the
# nightly rebuild. 146 KB total.
#
# TO REGENERATE (after a version bump, or for upstream fixes):
#
#   curl -X POST https://vanillatweaks.net/assets/server/zipdatapacks.php \
#     --data-urlencode 'version=1.21' \
#     --data-urlencode 'packs={"convenience":["multiplayer sleep","unlock all recipes"],
#                              "gameplay":["graves"],"informative":["coordinates hud"]}'
#
# ...then unpack the four inner zips over packages/minecraft-datapacks/, KEEPING the vt-*
# names -- minecraft-server.nix prunes exactly that glob, so a rename orphans the old copy
# in the world.
#
# Every pack declares supported_formats 48-94 (MC 1.21 - 1.21.11). Nothing in Nix checks it;
# a newer server just logs them incompatible and skips them.
pkgs.runCommand "minecraft-datapacks-vanillatweaks"
  {
    # The zips carry their version in pack.mcmeta, not the filename.
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
