{ config, lib, ... }:
# calibre-web ebook library, reachable only over WireGuard/LAN at
# https://calibre.luckyobserver.com.
#
# NOTE: calibre-web requires an existing Calibre library (metadata.db) at
# `calibreLibrary` or the service will fail to start. Initialise it once:
#   calibredb add --library-path /var/lib/calibre-web/library --empty
# (or import any book), then restart calibre-web.
# Library lives on root; backed up via Borg (modules/backup.nix).
{
  services.calibre-web = {
    enable = true;
    listen.ip = "127.0.0.1";
    listen.port = 8083;
    options = {
      calibreLibrary = "/var/lib/calibre-web/library";
      enableBookUploading = true;
    };
  };

  services.nginx.virtualHosts."calibre.luckyobserver.com" = {
    useACMEHost = "luckyobserver.com";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8083";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 1G;
      '';
    };
  };
}
