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
  imports = [ ./wg-endpoint.nix ];

  # Picks up the host's sops.defaultSopsFile, which modules/family/profile.nix forces to
  # secrets/family.yaml -- the only file these machines' age key can read.
  sops.secrets.${self.secret} = { };

  networking.wg-quick.interfaces.${fam.interface} = {
    # /32, not /24. With a host address and host routes, wg-quick adds exactly the two
    # routes below and nothing that could shadow the local network -- so unlike
    # hosts/sulfur.nix's wg0 there is no need for `table = "off"` and a hand-built
    # high-metric route.
    address = [ "${self.address}/32" ];
    privateKeyFile = config.sops.secrets.${self.secret}.path;

    peers = [{
      publicKey = fam.publicKey;

      # This is the whole isolation story on the client side. The hub, and one more
      # address:
      #
      # ${adm.address} is sulfur, and it is REQUIRED, not a convenience. WireGuard will
      # not encapsulate a packet whose destination is absent from allowedIPs, so without
      # it this machine's sshd accepts sulfur's connection and then cannot reply -- admin
      # SSH hangs with no error anywhere. It grants no reach of its own: sulfur always
      # initiates, and hydrogen's FORWARD rules pass only port 22 in that direction.
      #
      # Everything else -- the LAN, the router's admin page at 10.0.0.2, the other
      # family laptops -- is simply not routable from here.
      allowedIPs = [ "${fam.address}/32" "${adm.address}/32" ];

      # A BOOTSTRAP VALUE, and deliberately an IP literal rather than
      # ${peers.endpointHost}. modules/family/wg-endpoint.nix owns endpoint selection
      # from here on and overwrites this within seconds of boot.
      #
      # It must not be a hostname: wg-quick resolves the endpoint while CREATING the
      # interface, and a failed lookup aborts the whole unit -- which then sits failed
      # and never retries. A laptop behind a captive portal, or one that boots before
      # DNS is up, would have no tunnel at all until someone restarted it by hand. An
      # address that is merely *wrong* when away from home is harmless by comparison;
      # wg-endpoint corrects it on the first run.
      endpoint = "${peers.lanEndpoint}:${toString fam.port}";

      # Keeps the NAT mapping alive so the hub can reach back, and bounds how long a
      # re-targeted endpoint takes to produce a handshake.
      persistentKeepalive = 25;
    }];
  };

  family.wgEndpoint = [{
    interface = fam.interface;
    inherit (fam) publicKey port;
    lanHost = peers.lanEndpoint;
    publicHost = peers.endpointHost;
  }];


  # Service names resolve to the hub rather than to hydrogen's LAN address, so they work
  # identically at home and away and never depend on the router's resolver. Same names
  # as the public ones, so the wildcard cert from modules/reverse-proxy.nix still
  # matches.
  networking.hosts.${fam.address} = peers.serviceNames;
}
