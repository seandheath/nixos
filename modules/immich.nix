{ config, lib, ... }:
# Immich photo/video server, reachable through the home tailnet at
# https://immich.luckyobserver.com. The module provisions its own PostgreSQL
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
  };

  # Don't start immich before the /data disk is mounted (media lives there now).
  # The module's real units are immich-server + immich-machine-learning (there is
  # no "immich" unit). Mirrors the RequiresMountsFor guard on the local borg job.
  systemd.services.immich-server.unitConfig.RequiresMountsFor = "/data";
  systemd.services.immich-machine-learning.unitConfig.RequiresMountsFor = "/data";

  fleet.vhosts.immich = { port = config.services.immich.port; maxBody = "50G"; readTimeout = "600s"; };
}
