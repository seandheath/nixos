{ config, lib, ... }:
# Immich photo/video server, reachable only over WireGuard/LAN at
# https://immich.nheath.com. The 25.11 module provisions its own PostgreSQL
# (with the pgvector/vectorchord extension) and Redis automatically.
{
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    mediaLocation = "/data/immich";
  };

  services.nginx.virtualHosts."immich.nheath.com" = {
    useACMEHost = "nheath.com";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:2283";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 50G;
        proxy_read_timeout 600s;
      '';
    };
  };

  # mediaLocation lives on the separate /data disk; gate startup on the mount.
  systemd.services.immich-server.unitConfig.RequiresMountsFor = "/data";
}
