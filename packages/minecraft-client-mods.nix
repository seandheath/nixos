{ pkgs }:
# The Fabric client mod set for hydrogen's Minecraft server (see docs/minecraft.md).
#
# One list, two machines: hydrogen's couch clients and sulfur's desktop client both
# point their instance's mods folder at this directory via minecraft-mods-link
# (modules/minecraft-mods.nix), so they cannot drift apart.
#
# EVERY MOD HERE IS CLIENT-SIDE. The server stays a plain vanilla jar with no loader
# (modules/minecraft-server.nix) -- nothing below is required of it, so a phone or
# laptop joining over the tunnel still installs nothing.
#
# TO ADD OR UPDATE A MOD:
#   1. Find the version on Modrinth for loader=fabric, game_version=1.21.10.
#   2. Add/edit an entry below. The hash is SRI-encoded sha512, which is exactly what
#      the API already returns in files[].hashes.sha512 (hex -- convert it):
#        curl -s https://api.modrinth.com/v2/version/<id> |
#          jq -r '.files[0].hashes.sha512' |
#          python3 -c 'import sys,base64,binascii; print("sha512-"+base64.b64encode(binascii.unhexlify(sys.stdin.read().strip())).decode())'
#   3. Rebuild, then re-run minecraft-mods-link (minecraft-couch-sync does it for you
#      on hydrogen).
#
# mcVersion below is asserted against pkgs.minecraft-server.version in
# modules/minecraft-mods.nix, so a nixpkgs bump that moves the server off 1.21.10
# fails the build here instead of showing the children an incompatible-mod wall.
let
  mcVersion = "1.21.10";

  # fetchurl needs an explicit `name`: Modrinth's CDN paths are URL-encoded (%2B for
  # the '+' in most version strings), and the derivation name would inherit that.
  fetchMod =
    {
      pname,
      version,
      filename,
      url,
      hash,
    }:
    {
      inherit pname version;
      name = filename;
      path = pkgs.fetchurl {
        name = filename;
        inherit url hash;
      };
    };

  mods = map fetchMod [
    # --- Dependencies of the mods below, not chosen for their own sake -------
    {
      # Required by Xaero's Minimap, Controlify and Better Name Visibility.
      pname = "fabric-api";
      version = "0.138.4+1.21.10";
      filename = "fabric-api-0.138.4+1.21.10.jar";
      url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/tV4Gc0Zo/fabric-api-0.138.4%2B1.21.10.jar";
      hash = "sha512-XmTFM5Hf0cBZd31nHFK+F6TieinZvXNA6p4/Vc56dws42woV4JZumB7owbk3L7iVQ6J4UhYkaJJorOu4W9XG6Q==";
    }
    {
      # Required by Controlify and Better Name Visibility -- the config-screen library.
      pname = "yet-another-config-lib";
      version = "3.8.2+1.21.10-fabric";
      filename = "yet_another_config_lib_v3-3.8.2+1.21.10-fabric.jar";
      url = "https://cdn.modrinth.com/data/1eAoo2KR/versions/skcT0J9K/yet_another_config_lib_v3-3.8.2%2B1.21.10-fabric.jar";
      hash = "sha512-d91NvvarLWCGPhrC9cTj66FrPmMH+6XZ1wwgYE4PcoY9ogliwqqZqO8VXevV5ghRxUk3MRsG4N1Nv07beng7AQ==";
    }
    {
      # Vanilla's menu has no entry point for a YACL screen, so without Mod Menu
      # Controlify and Better Name Visibility are configurable only by editing files
      # -- unworkable when the children are the ones adjusting nameplate size.
      pname = "modmenu";
      version = "16.0.1";
      filename = "modmenu-16.0.1.jar";
      url = "https://cdn.modrinth.com/data/mOgUt4GM/versions/pYbFlVtR/modmenu-16.0.1.jar";
      hash = "sha512-vgG7WoCjn8USI+8UJxO6PLwsI2WPDIvTbO7X7NFjaEt9yAjy7yPc5/s1C9/QEN6Xh/IXfhFcrj6pG5aoO9bqFg==";
    }
    {
      # Optional for Effortless Crafting, but it is what backs that mod's Mod Menu
      # config screen -- same reasoning as Mod Menu itself: without it the settings
      # exist only in a file. Client-only.
      pname = "cloth-config";
      version = "20.0.149+fabric";
      filename = "cloth-config-20.0.149-fabric.jar";
      url = "https://cdn.modrinth.com/data/9s6osm5g/versions/qMxkrrmq/cloth-config-20.0.149-fabric.jar";
      hash = "sha512-3x2eA0ncZPwIWfF7ZbZ7DXdFomtJBeh/wUjd68AoXeUaMlWEhZnw1e4k9qqwD7rEhJ1Au5BSk26qRS0hbHraYg==";
    }

    # --- The couch design's own requirements --------------------------------
    {
      # The renderer. The reason four clients on one GPU are comfortable at all.
      pname = "sodium";
      version = "mc1.21.10-0.7.3-fabric";
      filename = "sodium-fabric-0.7.3+mc1.21.10.jar";
      url = "https://cdn.modrinth.com/data/AANobbMI/versions/sFfidWgd/sodium-fabric-0.7.3%2Bmc1.21.10.jar";
      hash = "sha512-HMzcddly9cF2pIjcyEzOcyC2CKLRBUEvKEckWv+/WqIrGZXto5ITJFP6bhqRVKyZqHrK+NeYm58aI6wQWak9rw==";
    }
    {
      # Gamepad support and controller-driven menus -- without this the couch
      # clients cannot be played at all.
      pname = "controlify";
      version = "3.0.1+lts";
      filename = "controlify-3.0.1+lts+1.21.10-fabric.jar";
      url = "https://cdn.modrinth.com/data/DOUdJVEm/versions/6Hff0hlS/controlify-3.0.1%2Blts%2B1.21.10-fabric.jar";
      hash = "sha512-+hRryoF2ujaxBEdF+uVzlX9qwRjvOp1CHpV+TV9BpAW3x/dMGgiDtLwkRRQbkJOM9OVdW0Tayn3MaJHvmNdC6Q==";
    }

    # --- Quality of life ----------------------------------------------------
    {
      pname = "xaeros-minimap";
      version = "fabric-1.21.10-26.4.2";
      filename = "xaerominimap-fabric-1.21.10-26.4.2.jar";
      url = "https://cdn.modrinth.com/data/1bokaNcj/versions/mB3zUj6T/xaerominimap-fabric-1.21.10-26.4.2.jar";
      hash = "sha512-RS5svxmgKvZkBKc+nE0CtzFpgATFW9s3KLt07vFaTeGSdorBnBpI1jL9mYQbj/ccEEQyywof0sCSA15h5odDIg==";
    }
    {
      # Bigger, always-legible nameplates. On the couch this is a real fix, not a
      # nicety: four quarter-screen viewports of identical default skins are
      # genuinely hard to tell apart (see the "Everyone is Steve or Alex"
      # limitation in docs/minecraft.md).
      pname = "better-name-visibility";
      version = "2.0.2";
      filename = "name-visibility-2.0.2.jar";
      url = "https://cdn.modrinth.com/data/pSfNeCCY/versions/1ufRZHIA/name-visibility-2.0.2.jar";
      hash = "sha512-V4Pw9bjv7tMoL1jN8hPLB8zQ63Bhuuz0/N00IbZloeR++ohGBqEB0WHaZLbs6fX/icZnWxALswtehZ2Pws+zNQ==";
    }
    {
      # What am I looking at. The jar is named for 1.21.9 upstream but its Modrinth
      # version lists 1.21.9 AND 1.21.10 -- not a mispick.
      pname = "jade";
      version = "20.1.0+fabric";
      filename = "Jade-1.21.9-Fabric-20.1.0.jar";
      url = "https://cdn.modrinth.com/data/nvQzSEkH/versions/nCbsPtPw/Jade-1.21.9-Fabric-20.1.0.jar";
      hash = "sha512-F6W/qMGITc+NUiYVigeev9favUNl9NiXShZel5wk633l0fTY1qPdQbF892RappIi3HkE26r0DqyFGLfGKiZmRg==";
    }

    {
      # Craft using items in reachable chests without hauling them to the table.
      #
      # NOT "Nearby Crafting" (nearby-crafting), which is the better-known mod for
      # this and was what was actually asked for: it is server_side REQUIRED, so it
      # cannot work against a vanilla server. Effortless Crafting does the same job
      # entirely client-side -- verified from the jar, not the Modrinth metadata:
      # fabric.mod.json declares environment "client" (its mod id is "reachcrafting").
      # Craft From Chests was the other candidate and is likewise server-required.
      pname = "effortless-crafting";
      version = "fabric-1.21.10-v1.3.0";
      filename = "effortless-crafting-fabric-1.21.10-v1.3.0.jar";
      url = "https://cdn.modrinth.com/data/iMFvPhVJ/versions/qpvBiLaT/effortless-crafting-fabric-1.21.10-v1.3.0.jar";
      hash = "sha512-qnNdBqMcoglF4m4teCzheB8RuGzJO59ZjpQFqIqb556gqa9WIKikRLPXoxaDMMsY9zabAUvFbrGVYNfoCCdhkw==";
    }

    # NO RECIPE VIEWER, deliberately -- see docs/minecraft.md. Since 1.21.2 the recipe
    # list lives on the server and is no longer sent to clients, so a client-only
    # viewer cannot enumerate recipes against this vanilla server. JEI was tried and
    # says so in chat on every join; EMI never shipped past 1.21.1; REI's client-side
    # fallback is broken for any recipe unlocked in-game (shedaniel/RoughlyEnoughItems
    # #2063) and our Unlock All Recipes datapack unlocks all of them -- that fix is
    # merged (#2065, 2026-07-29) but unreleased on every branch as of 2026-08-04.
    #
    # The gap is smaller than it looks: Unlock All Recipes leaves every player's
    # vanilla recipe book complete, so forward lookup is covered. What is missing is
    # reverse lookup ("what is this ingredient for?") and the stations the recipe book
    # ignores -- brewing and smithing.
    #
    # TO REVISIT: check for a REI release dated after 2026-07-29 that supports the
    # server's version. If there is one, adding it here is the whole change.
  ];
in
# linkFarm rather than a copy: the jars stay shared in the store, and Fabric follows
# symlinks out of the mods directory happily. (Note this is NOT true inside a world
# directory -- see the datapack handling in modules/minecraft-server.nix.)
(pkgs.linkFarm "minecraft-client-mods-${mcVersion}" mods).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit mcVersion;
      # Consumed by docs and by anyone wondering what is actually in here.
      modList = map (m: "${m.pname} ${m.version}") mods;
    };
  })
