{ config, ... }:
# HTTP-only internal reverse proxy on hydrogen.
#
# TLS is terminated upstream on the ROUTER (which holds the Cloudflare token and the
# *.luckyobserver.com wildcard cert). The router proxies https://<svc>.luckyobserver.com
# to http://10.0.0.2 preserving the Host header; this nginx then routes by Host on port 80
# to the local services. Nextcloud's php-fpm needs a local webserver regardless, so nginx
# stays on hydrogen -- just without ACME/TLS.
{
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
  };

  # Per-service virtualHosts (http, port 80) are defined in each service module
  # (nextcloud.nix auto-creates its own; immich/calibre/paperless define theirs).
}
