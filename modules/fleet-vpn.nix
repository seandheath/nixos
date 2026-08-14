# Fleet WireGuard access to a Jellyfin server at 100.64.0.80.
#
# The grant is ONE device record, so it cannot be live on sulfur and hydrogen at once --
# the hub keys the endpoint by public key and concurrent use flaps the handshake. Both
# declare it with autoconnect/autostart off; switch by hand, one host at a time:
#   sulfur    nmcli connection up|down fleet, or the GNOME panel toggle
#   hydrogen  systemctl start|stop wg-quick-fleet
#
# Two implementations of one tunnel: sulfur uses an NM profile so it appears in the panel,
# which is what a hand-switched tunnel wants; hydrogen keeps wg-quick because nobody
# switches a server from its panel. Connects by IP, so no tunnel DNS.
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
          # The issued conf ships AllowedIPs empty. These are narrow and do not overlap the
          # home LAN, so no table = "off" route suppression is needed.
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


  # Pinned so the first SSH is verified rather than trust-on-first-use.
  programs.ssh.knownHosts.fleet-jellyfin = {
    hostNames = [ "100.64.0.80" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFd0ZwFQwDQsRZFssVJeqIt53gwcMy+9wYT9APllnngV";
  };

  # System-level so hydrogen gets it without a managed ~/.ssh/config; on sulfur the user's
  # own identical alias is read first and wins.
  programs.ssh.extraConfig = ''
    Host jellyfin
      HostName 100.64.0.80
      User sheath
      IdentityFile ${fleetSshKey}
      IdentitiesOnly yes
  '';
}
