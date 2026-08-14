# Fleet WireGuard access for sheath (see ~/Downloads/README.md, "Fleet access
# for sheath"). Admits this device's /32 (172.20.20.6) to a management VPN
# (hub 172.20.20.1) and reaches a Jellyfin server at 100.64.0.80 over the tunnel
# (shell + SFTP as user `sheath`, media group r/w).
#
# The grant is ONE device record — a single key/address. It cannot be live on
# sulfur and hydrogen at the same time (the hub keys the endpoint by public
# key; concurrent use flaps the handshake). Both hosts therefore declare the
# identical tunnel with autoconnect/autostart DISABLED, and it is switched by
# hand — exactly one host up at a time:
#   sulfur:    nmcli connection up fleet     / nmcli connection down fleet
#              (or the GNOME network panel toggle — same thing)
#   hydrogen:  sudo systemctl start wg-quick-fleet
#              sudo systemctl stop  wg-quick-fleet
#
# TWO IMPLEMENTATIONS OF ONE TUNNEL, and the split is deliberate. sulfur builds
# it as a NetworkManager profile so it appears in the GNOME panel — a hand-
# switched tunnel is exactly what a toggle is good for, and NM owning the config
# makes that toggle safe (see the header in hosts/sulfur.nix). hydrogen keeps
# wg-quick: it is a server, nobody is switching this from its panel, and there
# is no reason to move a working tunnel on the machine everything depends on.
# hydrogen's copy is protected from NM by modules/wg-unmanaged.nix instead.
#
# We connect to the server by IP, so no tunnel-provided DNS is configured
# (keeps hydrogen clear of resolvconf).
{ config, lib, ... }:
let
  isHydrogen = config.networking.hostName == "hydrogen";

  # Declared once and shared by both implementations below, so the two copies of this
  # tunnel cannot drift apart in the way that matters -- a peer key or endpoint that
  # differs between hosts is a tunnel that silently fails on one of them.
  fleetPeerKey = "JA/8p6kwD1fIripjtt27UGoN/cpyt9Fi4JpADIiCTT0=";
  fleetEndpoint = "173.212.3.77:51821";

  # The `ssh jellyfin` login key. sulfur already carries it on disk; hydrogen
  # is an impermanent server with no ~/.ssh, so it gets the key from sops.
  fleetSshKey =
    if isHydrogen then config.sops.secrets.fleet-ssh-key.path else "/home/sheath/.ssh/jellyfin";
in
{
  sops.secrets.wg-priv-fleet = { };

  # Fleet SSH login key — provisioned only where ~/.ssh doesn't already hold it
  # (hydrogen). owner/mode so ssh accepts it (private keys must be user-owned and
  # not group/other-readable). Same sops pattern as borg-ssh-key.
  sops.secrets.fleet-ssh-key = lib.mkIf isHydrogen {
    owner = "sheath";
    mode = "0400";
  };

  # hydrogen: wg-quick, unchanged.
  networking.wg-quick.interfaces = lib.mkIf isHydrogen {
    fleet = {
      autostart = false; # never up at boot; manual switch (see header)
      address = [ "172.20.20.6/32" ];
      mtu = 1420;
      privateKeyFile = config.sops.secrets.wg-priv-fleet.path;

      peers = [
        {
          publicKey = fleetPeerKey;
          endpoint = fleetEndpoint;
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
  };

  # sulfur: the same tunnel as a NetworkManager profile, so it is switchable from the
  # GNOME panel. Key stays in sops and is handed to NM by nm-file-secret-agent, never
  # written into the connection file.
  networking.networkmanager.ensureProfiles = lib.mkIf (!isHydrogen) {
    profiles.fleet = {
      connection = {
        id = "fleet";
        uuid = "b76bf7f9-25a0-4ea5-a7d4-88e3f46eec1f";
        type = "wireguard";
        interface-name = "fleet";
        autoconnect = false; # NEVER at boot -- one host at a time, see header
      };

      wireguard = {
        private-key-flags = 1;
        mtu = 1420;
        peer-routes = true;
      };

      # Same narrow allowed-ips as the wg-quick copy above, and for the same reason:
      # they don't overlap the 10.0.0.0/24 home LAN, so no route suppression is needed.
      "wireguard-peer.${fleetPeerKey}" = {
        allowed-ips = "172.20.20.0/24;100.64.0.80/32;";
        endpoint = fleetEndpoint;
        persistent-keepalive = 25;
      };

      ipv4 = {
        method = "manual";
        address1 = "172.20.20.6/32";
        never-default = true;
      };
      ipv6.method = "disabled";
    };

    secrets.entries = [{
      matchId = "fleet";
      matchType = "wireguard";
      matchSetting = "wireguard";
      key = "private-key";
      file = config.sops.secrets.wg-priv-fleet.path;
      trim = true;
    }];
  };


  # Pin the Jellyfin server's host key (README step 2) so the first SSH is
  # verified instead of trust-on-first-use.
  programs.ssh.knownHosts.fleet-jellyfin = {
    hostNames = [ "100.64.0.80" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFd0ZwFQwDQsRZFssVJeqIt53gwcMy+9wYT9APllnngV";
  };

  # `ssh jellyfin` -> sheath@100.64.0.80 over the fleet tunnel. Declared at the
  # system level (/etc/ssh/ssh_config) so hydrogen gets it without a managed
  # ~/.ssh/config; on sulfur the user's own ~/.ssh/config alias (read first)
  # takes precedence over this identical block. IdentitiesOnly mirrors the
  # user's `Host *` setting so only this key is offered.
  programs.ssh.extraConfig = ''
    Host jellyfin
      HostName 100.64.0.80
      User sheath
      IdentityFile ${fleetSshKey}
      IdentitiesOnly yes
  '';
}
