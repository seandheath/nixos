{ config, lib, ... }:
# paperless-ngx document management, reachable only over WireGuard/LAN at
# https://paper.luckyobserver.com. Documents dropped into the consume dir
# (<dataDir>/consume) or uploaded via the web UI are OCR'd and indexed.
# scanbd button-driven scanning from the MFC-L2707DW is deferred (out of scope).
{
  # ocrmypdf (a paperless dependency) ships a flaky test — test_exotic_image
  # [pdfa-hocr-cmyk.pdf] — that fails nondeterministically (JPEG/PDF-A decode).
  # Because it runs in the derivation's checkPhase it turns every off-cache
  # rebuild into a slow (~3 min) local build that can also just fail. We hit
  # this whenever nixpkgs is ahead of the binary cache (nightly autoUpgrade's
  # --override-input to the nixos-25.11 tip; `nb`/`nr` flake updates). Skip
  # ocrmypdf's tests so paperless builds fast and deterministically.
  #
  # Scoped via pythonPackagesExtensions (not a top-level pkgs.ocrmypdf override)
  # because paperless-ngx pulls ocrmypdf from the python package set. Blast
  # radius is ocrmypdf + its dependents (paperless), not all of Python.
  nixpkgs.overlays = [
    (final: prev: {
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (pyfinal: pyprev: {
          # paperless-ngx re-derives ocrmypdf as `ocrmypdf.override { tesseract
          # = tesseract5; }`, which re-runs the package function and resets
          # doCheck to its default (true) — so a plain overrideAttrs/​
          # overridePythonAttrs is discarded. Re-expose `.override` (which
          # overridePythonAttrs drops here) and re-apply doCheck=false *after*
          # any arg override, so tesseract5 AND disabled tests both stick.
          ocrmypdf =
            let noCheck = p: p.overridePythonAttrs (_: { doCheck = false; });
            in (noCheck pyprev.ocrmypdf) // {
              override = args: noCheck (pyprev.ocrmypdf.override args);
            };
        })
      ];
    })
  ];

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

  services.nginx.virtualHosts."paper.luckyobserver.com" = {
    useACMEHost = "luckyobserver.com";
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:28981";
      proxyWebsockets = true;
      extraConfig = ''
        client_max_body_size 1G;
      '';
    };
  };

}
