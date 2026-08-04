{ pkgs, lib, ... }:
# Persistent vanilla Minecraft server for hydrogen (see docs/minecraft.md).
#
# Runs as a system service independent of any graphical session, so the world is
# joinable after a reboot with nobody logged in. Two classes of client:
#   - the couch clients (modules/minecraft-couch.nix) over 127.0.0.1, and
#   - remote devices over the router's WireGuard tunnel, which reach hydrogen at
#     its LAN address and therefore arrive on br0.
#
# THE SERVER IS DELIBERATELY VANILLA -- the stock jar, no mod loader. Every mod in
# the client stack (packages/minecraft-client-mods.nix) is client-side, so a
# phone/laptop/tablet joining from the tunnel needs no mod installation at all.
#
# The datapacks installed below do not change that. A datapack is vanilla
# data-driven content the server loads out of world/datapacks and pushes to clients
# as needed -- no loader, no client install, no join-time requirement. Keep it that
# way: anything that would need Fabric on the server breaks the unmodded-join
# guarantee for every remote device at once.
#
# SECURITY: online-mode=false means the server performs NO identity verification --
# anything that can reach 25565 may claim any username, and a whitelist does not
# help because it matches on names that are themselves unauthenticated. The
# network boundary is therefore the authentication boundary: openFirewall is off
# here and the port is scoped to br0 in hosts/hydrogen.nix (LAN + tunnel peers,
# never the internet -- the router forwards only 51820/udp). Residual risk: one
# child can log in as a sibling. Known; not worth more machinery.
let
  datapacks = import ../packages/minecraft-datapacks.nix { inherit pkgs; };
in
{
  services.minecraft-server = {
    enable = true;
    eula = true;

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

      # Dominant lever on server CPU with five concurrent clients, and
      # imperceptible at quarter-screen. Raise only if remote (full-screen)
      # players complain about pop-in.
      view-distance = 10;
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
  '';

  # /data is not involved, but the world lives on root which is always mounted --
  # no RequiresMountsFor needed here (unlike immich/borg, see modules/backup.nix).
}
