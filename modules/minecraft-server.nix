{ pkgs, lib, ... }:
# Persistent vanilla Minecraft server for hydrogen (see docs/minecraft.md).
#
# Runs as a system service independent of any graphical session, so the world is
# joinable after a reboot with nobody logged in. Two classes of client:
#   - the couch clients (modules/minecraft-couch.nix) over 127.0.0.1, and
#   - every other device over one of hydrogen's own WireGuard hubs
#     (modules/family/vpn-hub.nix): the kids' laptops and phones on wgfam, sulfur on
#     wgadm. As of 2026-08-06 the LAN is NOT one of them -- see SECURITY below.
#
# THE SERVER RUNS FABRIC (packages/fabric-server.nix), over the same vanilla jar.
# It was deliberately loader-free until 2026-08-04; what changed and why:
#
# Since Minecraft 1.21.2 the recipe list and container contents live server-side and
# are no longer sent to clients. Two things follow, and neither has a client-side
# answer:
#   - no recipe viewer works. JEI says so in chat on every join, EMI never shipped
#     past 1.21.1, and REI's local fallback is broken by our own Unlock All Recipes
#     datapack (shedaniel/RoughlyEnoughItems#2063, fix merged but unreleased).
#   - crafting from nearby chests can only be approximated, by a client mod that
#     opens each chest over the network behind a held Ctrl -- a key the couch
#     gamepads do not have, so on a pad the feature was unreachable.
# Both are solved by a mod ON THE SERVER, and only there. See docs/minecraft.md.
#
# THE UNMODDED-JOIN GUARANTEE STILL HOLDS, and is the thing to re-verify after any
# change to the server mod set: a phone/laptop/tablet must still join over the
# tunnel with nothing installed. It holds because none of the server mods add
# registry entries (Nearby Crafting is 7 classes and touches no registry; JEI adds
# no content), so Fabric API's registry sync -- the mechanism that can actually
# reject a vanilla client -- has nothing to synchronise. Test it, do not assume it.
#
# Datapacks are unaffected either way: vanilla data-driven content out of
# world/datapacks, no loader and no client install involved.
#
# SECURITY: online-mode=false means the server performs NO identity verification --
# anything that can reach 25565 may claim any username, and a whitelist does not
# help because it matches on names that are themselves unauthenticated. The
# network boundary is therefore the authentication boundary.
#
# That boundary USED TO BE THE HOME LAN, which is a weak thing to authenticate with:
# openFirewall is off here and the port was scoped to br0, so any device on the wifi --
# a guest phone, anything that ever learned the passphrase -- could join as any child.
# Since 2026-08-06 the port is scoped to hydrogen's own WireGuard interfaces instead
# (hosts/hydrogen.nix, modules/family/vpn-hub.nix), so joining requires a private key
# rather than proximity. Residual risk is unchanged and still accepted: one child can
# log in as a sibling, because they are peers of equal standing on wgfam.
let
  datapacks = import ../packages/minecraft-datapacks.nix { inherit pkgs; };
  mods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };
  fabricServer = import ../packages/fabric-server.nix { inherit pkgs; };
in
{
  # HOLD THE VANILLA JAR AT 1.21.10 (2026-08-10). nixpkgs 26.05 ships 1.21.11, but
  # items 2-4 of the VERSION LOCKSTEP below -- Fabric intermediary mappings, the
  # Modrinth mod pins and the client payload -- are all still 1.21.10, so the
  # assertions correctly refuse to build. Pinning the jar keeps all five in step and
  # makes the 1.21.11 migration a deliberate change rather than a side effect of a
  # channel bump; nixpkgs no longer carries a per-patch attribute for 1.21.10
  # (minecraftServers.vanilla-1-21 is the 1.21.11 build), hence the explicit src.
  #
  # Mojang serves old server jars indefinitely from piston-data; url and sha1 are
  # transcribed from nixpkgs 25.11's minecraft-servers/versions.json. Java is
  # unchanged (21) between the two releases, so the inherited wrapper is correct.
  #
  # REMOVE THIS once the Minecraft stack moves to 1.21.11 as a unit.
  nixpkgs.overlays = [
    (final: prev: {
      minecraft-server = prev.minecraft-server.overrideAttrs (_: {
        version = "1.21.10";
        src = prev.fetchurl {
          url = "https://piston-data.mojang.com/v1/objects/95495a7f485eedd84ce928cef5e223b757d2f764/server.jar";
          sha1 = "95495a7f485eedd84ce928cef5e223b757d2f764";
        };
      });
    })
  ];

  services.minecraft-server = {
    enable = true;
    eula = true;

    # Fabric Loader over the same vanilla jar (packages/fabric-server.nix), NOT the
    # stock package. See the header for why the server stopped being loader-free.
    package = fabricServer;

    # Keep server.properties in Nix rather than letting the server rewrite it.
    # The module backs up any pre-existing stateful file as .stateful on the
    # first declarative switch.
    declarative = true;

    # NOT openFirewall -- that would open 25565 globally. See the header.
    openFirewall = false;

    # Root SSD (~400G free after the 2026-07 immich migration). Included in
    # backupPaths in modules/backup.nix; the borg jobs flush the world through
    # /run/minecraft-server.stdin first so archives aren't torn mid-save.
    dataDir = "/var/lib/minecraft";

    # 31 GiB installed. Budget: 6G server + 4x3G clients + desktop/services.
    # G1 with a bounded pause target -- a larger heap here would only lengthen
    # collections, which surface as tick lag for every player at once.
    jvmOpts = builtins.concatStringsSep " " [
      "-Xms4G"
      "-Xmx6G"
      "-XX:+UseG1GC"
      "-XX:+ParallelRefProcEnabled"
      "-XX:MaxGCPauseMillis=200"
      "-XX:+DisableExplicitGC" # ignore System.gc() from mods/plugins
    ];

    serverProperties = {
      server-port = 25565;

      # Required: the couch clients are offline accounts (no Microsoft auth per
      # child). Offline UUIDs derive from a hash of the username, so the four
      # usernames in modules/minecraft-couch.nix must stay distinct and fixed --
      # renaming one orphans that child's inventory and advancements.
      online-mode = false;

      # Must accompany online-mode=false. With secure chat enforced, an
      # unauthenticated client has no Mojang-signed chat key and is kicked on the
      # first message ("Chat disabled due to missing profile public key").
      enforce-secure-profile = false;

      # A whitelist matches on unauthenticated names, so it buys nothing here.
      # The firewall scoping is the real control.
      white-list = false;

      # THE TWO ARE NOT THE SAME LEVER, which is why only one of them moved.
      #
      # view-distance is how far chunks are SENT: it costs chunk tracking, memory and
      # bandwidth, and it is the one a player actually sees as draw distance.
      # simulation-distance is how far chunks TICK -- mobs, redstone, crops, hoppers --
      # and that is where the CPU goes. Raising the cheap one and leaving the expensive
      # one alone buys the visible improvement at roughly none of the tick cost.
      #
      # 10 -> 12 was the vanilla client default all along, so every player on a default
      # slider was being clipped by the server rather than by their own setting. It is
      # +42% chunks tracked ((2*12+1)^2 vs (2*10+1)^2), not +42% CPU.
      #
      # Raised 2026-08-10 for the remote full-screen players -- sulfur and the guest peer
      # on wgfam -- which is exactly the condition the previous comment here said to wait
      # for. The couch clients are at quarter-screen and will not notice either way.
      # If it needs to go further, 16 is the next stop, but that is 2.5x the chunks of
      # the original and worth watching `tick` timings for first.
      view-distance = 12;
      simulation-distance = 8;

      max-players = 10;
      spawn-protection = 0; # kids build at spawn
      difficulty = "normal";
      gamemode = "survival";
      motd = "hydrogen";

      # server-ip is deliberately UNSET. Binding to a single address would break
      # either loopback (couch) or the LAN address (tunnel); interface scoping is
      # the firewall's job.
    };
  };

  # ---------------------------------------------------------------------------
  # Datapacks (packages/minecraft-datapacks.nix).
  #
  # Appended to the nixpkgs module's own preStart, which is a plain string option --
  # it runs as User=minecraft with WorkingDirectory=dataDir, which is why the stock
  # body can say `ln -sf ... eula.txt` unqualified and why the relative paths below
  # are correct.
  #
  # DELETE-THEN-COPY, NOT JUST COPY. Dropping a pack from Nix has to remove it from
  # the world too, or the set is merely additive and drifts. The vt- prefix bounds
  # what this will delete, so a datapack dropped in by hand is never touched.
  #
  # COPY, NOT SYMLINK. Since 1.19.4 Minecraft refuses to follow symlinks inside a
  # world directory unless they are listed in allowed_symlinks.txt, so the obvious
  # systemd.tmpfiles "L+" approach yields a world with silently zero datapacks. This
  # also matches how modules/veloren-server.nix installs its settings.ron.
  #
  # No /datapack enable is needed: vanilla auto-enables packs it finds at world load,
  # and changing the unit means switch restarts the server anyway.
  systemd.services.minecraft-server.preStart = lib.mkAfter ''
    mkdir -p world/datapacks
    find world/datapacks -maxdepth 1 -name 'vt-*.zip' -delete
    cp ${datapacks}/vt-*.zip world/datapacks/
    chmod 0644 world/datapacks/vt-*.zip

    # Server-side mods. Same delete-then-copy discipline as the datapacks: dropping a
    # mod from Nix has to remove it from the server, or the set is merely additive.
    # Everything here is a *.jar we put there, so unlike the datapacks there is no
    # prefix to bound the delete -- which also means a jar dropped in by hand WILL be
    # removed. Add mods to packages/minecraft-client-mods.nix instead.
    #
    # Copies rather than symlinks purely for consistency with the datapacks; Fabric
    # would follow symlinks here (the mods dir is not inside the world).
    mkdir -p mods
    find mods -maxdepth 1 -name '*.jar' -delete
    cp ${mods.server}/*.jar mods/
    chmod 0644 mods/*.jar
  '';

  # VERSION LOCKSTEP. Five things have to agree on the Minecraft version now, and the
  # nightly auto-update moves the first of them without asking:
  #   1. pkgs.minecraft-server        the game jar          (nixpkgs)
  #   2. fabric-server.nix mcVersion  intermediary mappings (pinned by hash)
  #   3. client mods mcVersion        Modrinth pins         (modules/minecraft-client.nix)
  #   4. the pinned client payload    Mojang manifest pins  (packages/minecraft-client)
  #   5. the datapacks' format window (server log only, cannot be checked here)
  #
  # 2 is the dangerous one: intermediary maps obfuscated names for ONE game version,
  # so a bumped jar against stale mappings fails at runtime, in the dark, at whatever
  # hour the auto-update ran. Catch it at eval instead. (3 and 4 are asserted in
  # modules/minecraft-client.nix, which also covers sulfur.)
  assertions = [
    {
      assertion = fabricServer.mcVersion == pkgs.minecraft-server.version;
      message = ''
        Minecraft version drift: nixpkgs ships minecraft-server ${pkgs.minecraft-server.version}
        but packages/fabric-server.nix pins Fabric intermediary mappings for ${fabricServer.mcVersion}.

        Re-transcribe the launch profile for the new version:
          curl -s https://meta.fabricmc.net/v2/versions/loader/${pkgs.minecraft-server.version}/<loader>/server/json
        then bump mcVersion and the intermediary hash. Check the server mods support
        the new version first -- packages/minecraft-client-mods.nix.
      '';
    }
  ];

  # /data is not involved, but the world lives on root which is always mounted --
  # no RequiresMountsFor needed here (unlike immich/borg, see modules/backup.nix).
}
