# Fleet WireGuard access for sheath (see ~/Downloads/README.md, "Fleet access
# for sheath"). Admits this device's /32 (172.20.20.6) to a management VPN
# (hub 172.20.20.1) and reaches a Jellyfin server at 100.64.0.80 over the tunnel
# (shell + SFTP as user `sheath`, media group r/w).
#
# The grant is ONE device record — a single key/address. It cannot be live on
# sulphur and hydrogen at the same time (the hub keys the endpoint by public
# key; concurrent use flaps the handshake). Both hosts therefore declare the
# identical tunnel with autostart DISABLED, and it is switched by hand — exactly
# one host up at a time:
#   sudo systemctl start wg-quick-fleet    # bring up on THIS host
#   sudo systemctl stop  wg-quick-fleet    # take down before using the other host
#
# We connect to the server by IP, so no tunnel-provided DNS is configured
# (keeps hydrogen clear of resolvconf).
{ config, lib, ... }:
{
  sops.secrets.wg-priv-fleet = { };

  networking.wg-quick.interfaces.fleet = {
    autostart = false; # never up at boot; manual switch (see header)
    address = [ "172.20.20.6/32" ];
    mtu = 1420;
    privateKeyFile = config.sops.secrets.wg-priv-fleet.path;

    peers = [
      {
        publicKey = "JA/8p6kwD1fIripjtt27UGoN/cpyt9Fi4JpADIiCTT0=";
        endpoint = "173.212.3.77:51821";
        # The issued conf ships AllowedIPs empty (routes are left to the client /
        # the optional FleetConnect renderer). Supply exactly what we need to
        # reach: the management VPN + hub (172.20.20.0/24) and the Jellyfin host
        # (100.64.0.80/32). These are narrow and don't overlap the 10.0.0.0/24
        # home LAN, so no `table = "off"` route-suppression is needed.
        allowedIPs = [ "172.20.20.0/24" "100.64.0.80/32" ];
        persistentKeepalive = 25;
      }
    ];
  };

  # WireGuard reply traffic returns on the tunnel iface; loosen reverse-path
  # filtering so it isn't dropped. mkDefault so sulphur's existing plain "loose"
  # (hosts/sulphur.nix) still wins without a conflict, and hydrogen (which sets
  # nothing) inherits it.
  networking.firewall.checkReversePath = lib.mkDefault "loose";

  # Pin the Jellyfin server's host key (README step 2) so the first SSH is
  # verified instead of trust-on-first-use.
  programs.ssh.knownHosts.fleet-jellyfin = {
    hostNames = [ "100.64.0.80" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFd0ZwFQwDQsRZFssVJeqIt53gwcMy+9wYT9APllnngV";
  };
}
