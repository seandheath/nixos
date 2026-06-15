{ config, pkgs, lib, ... }:
# Nextcloud on hydrogen, reachable only over WireGuard/LAN at https://nc.nheath.com.
# The nextcloud module generates its own nginx vhost on `hostName`; we attach the
# wildcard *.nheath.com cert (defined in reverse-proxy.nix) to it below.
{
  # Admin password sourced from sops (reuses the pre-existing secret).
  sops.secrets.nextcloud-adminpass.owner = "nextcloud";

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud32;
    hostName = "nc.nheath.com";
    https = true;
    datadir = "/data/nextcloud";
    database.createLocally = true;   # provisions local PostgreSQL (no dbpass needed)
    configureRedis = true;           # local Redis for file locking / caching
    config = {
      adminuser = "admin";
      adminpassFile = config.sops.secrets.nextcloud-adminpass.path;
      dbtype = "pgsql";
    };
    settings = {
      trusted_domains = [ "nc.nheath.com" "10.0.0.2" ];
      overwriteprotocol = "https";   # we terminate TLS at nginx in front of php-fpm
    };
  };

  services.nginx.virtualHosts."nc.nheath.com" = {
    useACMEHost = "nheath.com";
    forceSSL = true;
  };
}
