{ config, lib, ... }:
# paperless-ngx document management, reachable through the home tailnet at
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
    # Data (SQLite DB + media + consume) lives on root (/var/lib/paperless);
    # backed up via Borg (modules/backup.nix).
    passwordFile = config.sops.secrets.paperless-adminpass.path;
    settings = {
      PAPERLESS_URL = "https://paper.luckyobserver.com";
      PAPERLESS_OCR_LANGUAGE = "eng";
    };
  };

  fleet.vhosts.paper.port = 28981;

}
