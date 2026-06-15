{ config, lib, ... }:
# calibre-web ebook library, reachable only over WireGuard/LAN at
# https://calibre.nheath.com.
#
# NOTE: calibre-web requires an existing Calibre library (metadata.db) at
# `calibreLibrary` or the service will fail to start. Initialise it once:
#   calibredb add --library-path /data/calibre-library --empty
# (or import any book), then restart calibre-web.
{
  services.calibre-web = {
    enable = true;
    listen.ip = "127.0.0.1";
    listen.port = 8083;
    options = {
      calibreLibrary = "/data/calibre-library";
      enableBookUploading = true;
    };
  };

  services.nginx.virtualHosts."calibre.nheath.com" = {
    useACMEHost = "nheath.com";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8083";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 1G;
      '';
    };
  };

  # calibreLibrary lives on the separate /data disk; gate startup on the mount.
  systemd.services.calibre-web.unitConfig.RequiresMountsFor = "/data";
}
