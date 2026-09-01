{ config, lib, ... }:
# calibre-web ebook library, reachable through the home tailnet at
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

  fleet.vhosts.calibre.port = 8083;
}
