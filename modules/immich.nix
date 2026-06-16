{ config, lib, ... }:
# Immich photo/video server, reachable only over WireGuard/LAN at
# https://immich.luckyobserver.com. The 25.11 module provisions its own PostgreSQL
# (with the pgvector/vectorchord extension) and Redis automatically.
{
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    # Media lives on root (/var/lib/immich); backed up via Borg (modules/backup.nix).
  };

  services.nginx.virtualHosts."immich.luckyobserver.com" = {
    useACMEHost = "luckyobserver.com";
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
}
