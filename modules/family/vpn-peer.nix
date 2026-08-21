# Family-tunnel client. Imported by the four kids' laptops (via
# modules/family/profile.nix), and by nothing else.
#
# Which peer this host is comes from networking.hostName, so the module configures
# itself and there is no second place to keep a hostname in step.
{ config, lib, ... }:
let
  peers = import ./peers.nix;
  fam = peers.hubs.fam;
  adm = peers.admin.sulfur;

  hostName = config.networking.hostName;
  self = peers.family.${hostName} or (throw ''
    modules/family/vpn-peer.nix: no entry for host "${hostName}" in modules/family/peers.nix.
    Add one (address, publicKey, secret) before importing this module.
  '');
in
{
  # Picks up the host's sops.defaultSopsFile, which modules/family/profile.nix forces to
  # secrets/family.yaml -- the only file these machines' age key can read.
  sops.secrets.${self.secret} = { };

  networking.wireguard.interfaces.${fam.interface} = {
    # /32, not /24: host address plus host routes means nothing here can shadow the local
    # network, so no table = "off" and hand-built metric, unlike sulfur's wg0.
    ips = [ "${self.address}/32" ];
    privateKeyFile = config.sops.secrets.${self.secret}.path;

    peers = [{
      publicKey = fam.publicKey;

      # The whole client-side isolation story. sulfur's address is REQUIRED, not a
      # convenience: WireGuard will not encapsulate a packet whose destination is absent
      # here, so without it sshd accepts sulfur's connection and cannot reply -- admin SSH
      # hangs with no error anywhere. It grants no reach of its own. Everything else -- the
      # LAN, the router, the sibling laptops -- is simply not routable from here.
      allowedIPs = [ "${fam.address}/32" "${adm.address}/32" ];

      # Public DNS follows the dynamic WAN address; the router's split-horizon record
      # resolves this directly to hydrogen on every home VLAN.
      endpoint = "${peers.hydrogenEndpointHost}:${toString fam.port}";

      # Keeps the NAT mapping alive so the hub can reach back.
      persistentKeepalive = 25;
    }];
  };

  # Resolve to the hub, not hydrogen's LAN address, so they work identically at home and
  # away and never depend on the router's resolver.
  networking.hosts.${fam.address} = peers.serviceNames;
}
