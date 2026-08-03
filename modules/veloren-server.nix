{ pkgs, ... }:
# Persistent Veloren server for hydrogen (see docs/veloren.md).
#
# Veloren is an open-source voxel RPG. Like modules/minecraft-server.nix this runs as a
# system service independent of any graphical session, so the world is joinable after a
# reboot with nobody logged in. Same two classes of client: machines on the home LAN, and
# remote devices over the router's WireGuard tunnel, which reach hydrogen at its LAN
# address and therefore arrive on br0.
#
# THERE IS NO services.veloren IN NIXPKGS. nixpkgs ships only pkgs.veloren, a single
# derivation containing both veloren-server-cli and veloren-voxygen (the client), so the
# unit below is hand-written.
#
# VERSION LOCK-STEP. Veloren refuses connections between mismatched versions, and the
# server and client here are the same derivation -- so a client must be *exactly* the
# pkgs.veloren from this flake pin (0.17.0). Airshipper is NOT a substitute: it self-updates
# to upstream's weekly nightlies, which will not connect. hosts/hydrogen.nix and
# hosts/sulfur.nix therefore install pkgs.veloren directly.
#
# SECURITY: auth_server_address is None, so the server performs NO identity verification --
# anything that can reach 14004 may claim any username. This mirrors the Minecraft server's
# online-mode=false, and for the same reason: the household has no veloren.net accounts. The
# network boundary is therefore the authentication boundary; the port is scoped to br0 in
# hosts/hydrogen.nix (LAN + tunnel peers, never the internet -- the router forwards only
# 51820/udp). A whitelist would match on names that are themselves unauthenticated, so it
# buys nothing. Residual risk: one player can log in as another. Known; accepted.
let
  # Upstream defaults: 14004 game (TCP), 14006 query (UDP), 14005 server-cli web (loopback).
  gamePort = 14004;
  queryPort = 14006;

  stateDir = "/var/lib/veloren";

  # DO NOT CHANGE world_seed. Veloren does not store the world -- it regenerates it from the
  # seed on every start (~6s), and saves/ holds only terrain diffs and the character SQLite
  # DB. A new seed therefore replaces the world wholesale and orphans every player-made
  # change and waypoint. This value is the world; treat it like a database identifier.
  # 20260803 = the date this world was created.
  worldSeed = 20260803;

  # Partial config: the server fills every unset field from its own defaults, so only the
  # values that matter here are named. Verified against 0.17.0 -- the server reads this file
  # and does not write it back, which is what makes installing it from the store each start
  # (see ExecStartPre) safe and idempotent.
  settingsFile = pkgs.writeText "veloren-settings.ron" ''
    (
        gameserver_protocols: [
            Tcp(address: "0.0.0.0:${toString gamePort}"),
        ],

        // See the SECURITY note in the module header. None == no identity verification.
        auth_server_address: None,

        // Server-browser ping (player count / MOTD). Harmless and br0-scoped like the rest.
        query_address: Some("0.0.0.0:${toString queryPort}"),

        world_seed: ${toString worldSeed},
        server_name: "hydrogen",
        max_players: 10,

        // Dominant lever on server CPU, exactly as view-distance is for Minecraft. Upstream
        // defaults to 65 chunks, which is far more than this box should spend: the same
        // 6c/12t Xeon E-2176M also runs the Minecraft server, immich and ollama. Raise only
        // if players actually complain about terrain pop-in.
        max_view_distance: Some(30),
    )
  '';
in
{
  # A static system user rather than DynamicUser: DynamicUser relocates state to
  # /var/lib/private/veloren behind a symlink, which only complicates the borg path in
  # modules/backup.nix for no benefit here.
  users.users.veloren = {
    isSystemUser = true;
    group = "veloren";
    home = stateDir;
    description = "Veloren game server";
  };
  users.groups.veloren = { };

  systemd.services.veloren-server = {
    description = "Veloren game server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = {
      # Overrides the compiled-in VELOREN_USERDATA_STRATEGY=system, which would otherwise
      # resolve to the service user's XDG data dir. Checked at runtime, ahead of the strategy.
      VELOREN_USERDATA = stateDir;
      RUST_LOG = "info";
    };

    serviceConfig = {
      Type = "simple";
      User = "veloren";
      Group = "veloren";
      StateDirectory = "veloren";
      StateDirectoryMode = "0750";
      WorkingDirectory = stateDir;

      # Reinstall the declarative config on every start, so a hand-edit is reverted by the
      # next restart -- the same contract as services.minecraft-server.declarative = true.
      # A copy, not a symlink into the store: a symlink would break if a future version ever
      # writes this file back. admins.ron / banlist.ron / whitelist.ron ARE runtime-editable
      # (the server rewrites them on /admin, /ban, ...) and are deliberately left stateful.
      ExecStartPre = "${pkgs.coreutils}/bin/install -Dm0644 ${settingsFile} ${stateDir}/server/server_config/settings.ron";

      # --non-interactive is mandatory under systemd: otherwise the server listens on stdin
      # and the terminal driver sends it SIGTTIN.
      ExecStart = "${pkgs.veloren}/bin/veloren-server-cli --non-interactive";

      Restart = "always";
      RestartSec = 10;

      # Hardening. The server needs nothing but its state dir and a socket.
      # MemoryDenyWriteExecute is deliberately omitted -- untested against this binary, and
      # not worth risking a startup failure on a service the kids use.
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictSUIDSGID = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };
}
