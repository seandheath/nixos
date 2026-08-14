{ config, lib, ... }:
# Immich photo/video server, reachable only over WireGuard/LAN at
# https://immich.luckyobserver.com. The 25.11 module provisions its own PostgreSQL
# (with the pgvector/vectorchord extension) and Redis automatically.
{
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    # Media lives on the big /data disk (/data/immich), off the small root SSD.
    # The dir must be pre-created and owned by immich (module doesn't create a
    # non-default mediaLocation). Backed up via Borg (modules/backup.nix).
    mediaLocation = "/data/immich";

    # Immich has fully migrated off pgvecto.rs to VectorChord, and 26.05 removed
    # database.enableVectors entirely (defining it is now a hard assertion). The
    # dead `vectors` extension is gone for good; VectorChord is the only vector
    # extension immich uses, and it is on by default. Nothing to set here.
  };

  # Don't start immich before the /data disk is mounted (media lives there now).
  # The module's real units are immich-server + immich-machine-learning (there is
  # no "immich" unit). Mirrors the RequiresMountsFor guard on the local borg job.
  systemd.services.immich-server.unitConfig.RequiresMountsFor = "/data";
  systemd.services.immich-machine-learning.unitConfig.RequiresMountsFor = "/data";

  fleet.vhosts.immich = { port = 2283; maxBody = "50G"; readTimeout = "600s"; };
}
