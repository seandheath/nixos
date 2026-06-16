{ config, pkgs, lib, ... }:
# Nextcloud on hydrogen, reachable only over WireGuard/LAN at https://nc.luckyobserver.com.
# The nextcloud module generates its own nginx vhost on `hostName`; we attach the
# wildcard *.luckyobserver.com cert (defined in reverse-proxy.nix) to it below.
{
  # Admin password sourced from sops (reuses the pre-existing secret).
  sops.secrets.nextcloud-adminpass.owner = "nextcloud";

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud32;
    hostName = "nc.luckyobserver.com";
    https = true;
    # Data lives on root (/var/lib/nextcloud); backed up via Borg (modules/backup.nix).
    database.createLocally = true;   # provisions local PostgreSQL (no dbpass needed)
    configureRedis = true;           # local Redis for file locking / caching
    config = {
      adminuser = "admin";
      adminpassFile = config.sops.secrets.nextcloud-adminpass.path;
      dbtype = "pgsql";
    };
    settings = {
      trusted_domains = [ "nc.luckyobserver.com" "10.0.0.10" ];
      overwriteprotocol = "https";   # we terminate TLS at nginx in front of php-fpm
    };
  };

  services.nginx.virtualHosts."nc.luckyobserver.com" = {
    useACMEHost = "luckyobserver.com";
    forceSSL = true;
  };
}
