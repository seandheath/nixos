{ pkgs, lib, ... }:
# Minecraft server for hydrogen (docs/minecraft.md). A system service, so the world is
# joinable after a reboot with nobody logged in.
#
# Runs Fabric, not stock: since 1.21.2 the recipe list and container contents are
# server-side and no longer sent to clients, so no recipe viewer and no chest-crafting mod
# can work client-side. The unmodded-join guarantee still holds and is what to re-verify
# after any change to the server mod set -- none of these mods add registry entries, so
# Fabric API's registry sync has nothing to reject a vanilla client over.
#
# SECURITY: online-mode=false means NO identity verification -- anything reaching 25565 may
# claim any username, and a whitelist matches on unauthenticated names. The network boundary
# is the authentication boundary, and it is hydrogen's WireGuard interfaces, not the LAN.
# Residual risk, accepted: one child can log in as a sibling.
let
  datapacks = import ../packages/minecraft-datapacks.nix { inherit pkgs; };
  mods = import ../packages/minecraft-client-mods.nix { inherit pkgs; };
  fabricServer = import ../packages/fabric-server.nix { inherit pkgs; };
  mcPin = import ../packages/minecraft-version.nix;
in
{
  # Hold the jar at the fleet-wide pin rather than whatever the channel ships.
  nixpkgs.overlays = [
    (final: prev: {
      minecraft-server = prev.minecraft-server.overrideAttrs (_: {
        inherit (mcPin) version;
        src = prev.fetchurl { inherit (mcPin) url sha1; };
      });
    })
  ];

  services.minecraft-server = {
    enable = true;
    eula = true;

    package = fabricServer;
    declarative = true;
    # NOT openFirewall: that opens 25565 globally. See the header.
    openFirewall = false;
    dataDir = "/var/lib/minecraft";

    # Budget on 31 GiB: 6G server + 4x3G clients + desktop/services. A larger heap would
    # only lengthen collections, which surface as tick lag for everyone at once.
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

      # Offline accounts: no Microsoft auth per child. UUIDs hash the username, so the
      # handles in minecraft-couch.nix must stay fixed -- a rename orphans that character.
      online-mode = false;
      # Must accompany online-mode=false, or an unauthenticated client is kicked on its
      # first message for having no Mojang-signed chat key.
      enforce-secure-profile = false;
      # Matches on unauthenticated names, so it buys nothing; the firewall is the control.
      white-list = false;

      # Not the same lever, which is why only one moved. view-distance is how far chunks
      # are SENT (tracking, memory, bandwidth) and is what a player sees as draw distance;
      # simulation-distance is how far they TICK, which is where the CPU goes. 12 is the
      # vanilla client default, so players on a default slider were being clipped by the
      # server. Next stop is 16, but watch `tick` timings first.
      view-distance = 12;
      simulation-distance = 8;

      max-players = 10;
      spawn-protection = 0; # kids build at spawn
      difficulty = "normal";
      gamemode = "survival";
      motd = "hydrogen";

      # server-ip deliberately UNSET: binding one address breaks either loopback (couch) or
      # the tunnel. Interface scoping is the firewall's job.
    };
  };

  # Appended to the nixpkgs module's preStart, which runs as User=minecraft with
  # WorkingDirectory=dataDir -- hence the relative paths.
  #
  # DELETE-THEN-COPY: dropping a pack from Nix has to remove it from the world, or the set
  # is merely additive. The vt- prefix bounds the delete, so a hand-dropped pack survives.
  # COPY, NOT SYMLINK: since 1.19.4 Minecraft refuses symlinks inside a world directory
  # unless listed in allowed_symlinks.txt, so a tmpfiles L+ yields silently zero datapacks.
  systemd.services.minecraft-server.preStart = lib.mkAfter ''
    mkdir -p world/datapacks
    find world/datapacks -maxdepth 1 -name 'vt-*.zip' -delete
    cp ${datapacks}/vt-*.zip world/datapacks/
    chmod 0644 world/datapacks/vt-*.zip

    # Same delete-then-copy discipline, but with no prefix to bound it -- a jar dropped in
    # by hand WILL be removed. Add mods to packages/minecraft-client-mods.nix.
    mkdir -p mods
    find mods -maxdepth 1 -name '*.jar' -delete
    cp ${mods.server}/*.jar mods/
    chmod 0644 mods/*.jar
  '';

  # Intermediary maps obfuscated names for ONE game version, so a bumped jar against stale
  # mappings fails at runtime, in the dark, at whatever hour the nightly ran. Catch it at
  # eval. The client-side pins are asserted in modules/minecraft-client.nix.
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
}
