{ config, ... }:
{
  security.acme = {
    acceptTerms = true;
    defaults.email = "se@nheath.com";
  };

  # Single wildcard cert for every internal service hostname, issued via the
  # Cloudflare DNS-01 challenge. Works for WireGuard/LAN-only hosts because
  # DNS-01 validates with a TXT record Cloudflare creates/removes — no public
  # A records or inbound 80/443 required.
  #
  # Secret `acme-dns-credentials` is an env file containing:
  #   CF_DNS_API_TOKEN=<token scoped to Zone:DNS:Edit on nheath.com>
  sops.secrets.acme-dns-credentials = {};
  security.acme.certs."nheath.com" = {
    domain = "*.nheath.com";
    dnsProvider = "cloudflare";
    environmentFile = config.sops.secrets.acme-dns-credentials.path;
    group = "nginx";   # let nginx read the issued cert/key
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
  };

  # Per-service virtualHosts are defined in each service module
  # (nextcloud.nix, immich.nix, calibre.nix, paperless.nix), all attaching to
  # the wildcard cert above via `useACMEHost = "nheath.com"`.
}
