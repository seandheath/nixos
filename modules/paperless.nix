{ config, lib, ... }:
# paperless-ngx document management, reachable only over WireGuard/LAN at
# https://paper.luckyobserver.com. Documents dropped into the consume dir
# (<dataDir>/consume) or uploaded via the web UI are OCR'd and indexed.
# scanbd button-driven scanning from the MFC-L2707DW is deferred (out of scope).
{
  # Initial superuser password from sops (new secret).
  sops.secrets.paperless-adminpass.owner = "paperless";

  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 28981;
    dataDir = "/data/paperless";
    passwordFile = config.sops.secrets.paperless-adminpass.path;
    settings = {
      PAPERLESS_URL = "https://paper.luckyobserver.com";
      PAPERLESS_OCR_LANGUAGE = "eng";
    };
  };

  # http vhost (port 80); TLS is terminated on the router in front of this host.
  services.nginx.virtualHosts."paper.luckyobserver.com" = {
    locations."/" = {
      proxyPass = "http://127.0.0.1:28981";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 1G;
      '';
    };
  };

  # dataDir (DB + media + consume) lives on the separate /data disk; gate startup
  # of every paperless unit on the mount.
  systemd.services.paperless-web.unitConfig.RequiresMountsFor = "/data";
  systemd.services.paperless-consumer.unitConfig.RequiresMountsFor = "/data";
  systemd.services.paperless-scheduler.unitConfig.RequiresMountsFor = "/data";
  systemd.services.paperless-task-queue.unitConfig.RequiresMountsFor = "/data";
}
