{ pkgs }:
# The Fabric client mod set. One list, two machines: hydrogen's couch clients and sulfur's
# desktop client both point mods/ here, so they cannot drift.
#
# Most are client-side, but the `server = true` entries are installed on the server too.
# None add registry entries, so the "any unmodded phone can join over the tunnel" guarantee
# holds -- test it rather than assuming it.
#
# TO ADD OR UPDATE: find the version on Modrinth for loader=fabric, game_version=1.21.10,
# add an entry, rebuild. The hash is SRI sha512, which the API returns as hex:
#   curl -s https://api.modrinth.com/v2/version/<id> | jq -r '.files[0].hashes.sha512' |
#     python3 -c 'import sys,base64,binascii; print("sha512-"+base64.b64encode(binascii.unhexlify(sys.stdin.read().strip())).decode())'
#
# mcVersion below is asserted against pkgs.minecraft-server.version and against the
# pinned client payload in modules/minecraft-client.nix, so a nixpkgs bump that moves
# the server off 1.21.10 fails the build here instead of showing the children an
# incompatible-mod wall.
let
  mcVersion = "1.21.10";

  # fetchurl needs an explicit `name`: Modrinth's CDN paths are URL-encoded (%2B for
  # the '+' in most version strings), and the derivation name would inherit that.
  #
  # `server = true` marks a jar that must ALSO be installed on the server
  # (modules/minecraft-server.nix installs exactly that subset). Every server mod is
  # already a client mod here, so the server set is a strict subset rather than a
  # second list with duplicated URLs and hashes to drift apart.
  fetchMod =
    {
      pname,
      version,
      filename,
      url,
      hash,
      server ? false,
    }:
    {
      inherit pname version server;
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
      server = true;
      version = "0.138.4+1.21.10";
      filename = "fabric-api-0.138.4+1.21.10.jar";
      url = "https://cdn.modrinth.com/data/P7dR8mSH/versions/tV4Gc0Zo/fabric-api-0.138.4%2B1.21.10.jar";
      hash = "sha512-XmTFM5Hf0cBZd31nHFK+F6TieinZvXNA6p4/Vc56dws42woV4JZumB7owbk3L7iVQ6J4UhYkaJJorOu4W9XG6Q==";
    }
    {
      # Required by Controlify and Better Name Visibility -- the config-screen library.
      pname = "yet-another-config-lib";
      server = true;
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
      server = true;
      version = "16.0.1";
      filename = "modmenu-16.0.1.jar";
      url = "https://cdn.modrinth.com/data/mOgUt4GM/versions/pYbFlVtR/modmenu-16.0.1.jar";
      hash = "sha512-vgG7WoCjn8USI+8UJxO6PLwsI2WPDIvTbO7X7NFjaEt9yAjy7yPc5/s1C9/QEN6Xh/IXfhFcrj6pG5aoO9bqFg==";
    }
    {
      # Required by Nearby Crafting -- exposes the server's recipe book to mods.
      pname = "recipe-book-access-api";
      server = true;
      version = "1.1.1+1.21.11";
      filename = "recipebookaccess-1.1.1.jar";
      url = "https://cdn.modrinth.com/data/aWgs4SgO/versions/KecMVi52/recipebookaccess-1.1.1.jar";
      hash = "sha512-wM1cfFGEjn+spx16EBxdHLvvLd0xTN+0f8ymM07rADxlJaoVwbTppSLn9ikWW3PKeVQpg6w3wDJYWXJNtfFWPA==";
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
      # Chest contents count as inventory when crafting, with no modifier key -- which is
      # why it works on a gamepad, where Controlify has no Ctrl. Replaced Effortless
      # Crafting, the client-only approximation used while the server was vanilla.
      #
      # Its Modrinth entry lists no dependencies; the jar disagrees and the jar wins --
      # fabric-api, recipebookaccess, yacl AND modmenu are hard depends. Mod Menu being
      # environment=client does not break a dedicated server: Fabric loads client-env jars
      # as dependency candidates.
      pname = "nearby-crafting";
      server = true;
      version = "1.0.5";
      filename = "nearbycrafting-1.0.5.jar";
      url = "https://cdn.modrinth.com/data/DsjH66Cm/versions/jk2uvIzj/nearbycrafting-1.0.5.jar";
      hash = "sha512-/veeu04wqPOS+f0uQmiqGXkGMi8HsmUrDC0g5IqIrJYV5yAwEApVHQGwcietGH77BstgRExXnkEbKwp1Znl+pw==";
    }
    {
      # Recipe viewer. Only works because JEI is on the server too: since 1.21.2 the
      # recipe list is server-side and is not sent to clients, so a client-only JEI
      # reports "JEI is missing recipes" in chat on every join -- which is exactly what
      # happened while the server was vanilla, and why this was removed once and is
      # back now.
      #
      # EMI is still the nicer viewer but stopped at 1.21.1. REI's 1.21.10 build has a
      # local fallback that our Unlock All Recipes datapack breaks
      # (shedaniel/RoughlyEnoughItems#2063); its fix merged 2026-07-29 but is
      # unreleased. JEI needs no such workaround now that the server can answer.
      pname = "jei";
      server = true;
      version = "26.3.0.31";
      filename = "jei-1.21.10-fabric-26.3.0.31.jar";
      url = "https://cdn.modrinth.com/data/u6dRKJwZ/versions/8yGN172x/jei-1.21.10-fabric-26.3.0.31.jar";
      hash = "sha512-5xdS8+RjJdLRGnugX93SGWotV1qEU/ivAoaNqzoy1MseFEh0ZOBmKpQryxiHby8aVnjUM66rv+Pf4K3BXiDtog==";
    }
  ];

  # Seeded once into a game directory's config/ and never overwritten -- anything a player
  # changes in Mod Menu is theirs to keep. Partial files are fine: Cloth Config deserializes
  # into a default-constructed object, so unlisted fields keep the mod's defaults.
  # Empty: Nearby Crafting's defaults need no adjustment. Kept because the seeding machinery
  # is the awkward part to re-derive.
  configDefaults = pkgs.linkFarm "minecraft-client-mod-configs-${mcVersion}" [ ];

  serverMods = builtins.filter (m: m.server) mods;
in
# linkFarm rather than a copy: the jars stay shared in the store, and Fabric follows
# symlinks out of the mods directory happily. (Note this is NOT true inside a world
# directory -- see the datapack handling in modules/minecraft-server.nix.)
(pkgs.linkFarm "minecraft-client-mods-${mcVersion}" mods).overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      inherit mcVersion configDefaults;
      # The subset that must also be installed on the server, consumed by
      # modules/minecraft-server.nix. Derived from the same entries as the client set,
      # so the two can never disagree on a version or a hash.
      server = pkgs.linkFarm "minecraft-server-mods-${mcVersion}" serverMods;
      serverModList = map (m: "${m.pname} ${m.version}") serverMods;
      # Consumed by docs and by anyone wondering what is actually in here.
      modList = map (m: "${m.pname} ${m.version}") mods;
    };
  })
