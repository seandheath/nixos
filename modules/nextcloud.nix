{ config, pkgs, lib, ... }:
# Nextcloud on hydrogen, reachable only over WireGuard/LAN at https://nc.luckyobserver.com.
# The nextcloud module auto-creates its own http nginx vhost on `hostName` (port 80).
# TLS is terminated on the router, which proxies to this host; trusted_proxies +
# overwrite* below tell Nextcloud it is actually served over https.
{
  # Admin password sourced from sops (reuses the pre-existing secret).
  sops.secrets.nextcloud-adminpass.owner = "nextcloud";

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud32;
    hostName = "nc.luckyobserver.com";
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
      trusted_domains = [ "nc.luckyobserver.com" "10.0.0.2" ];
      # TLS is terminated on the router (10.0.0.1); trust it as a proxy so Nextcloud
      # honours X-Forwarded-* and generates correct https URLs.
      trusted_proxies = [ "127.0.0.1" "10.0.0.1" ];
      overwriteprotocol = "https";
      overwritehost = "nc.luckyobserver.com";
    };
  };

  # Data dir lives on the separate /data disk; don't start before it is mounted.
  systemd.services.nextcloud-setup.unitConfig.RequiresMountsFor = "/data";
  systemd.services.phpfpm-nextcloud.unitConfig.RequiresMountsFor = "/data";
}
