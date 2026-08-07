# A resolver on hydrogen, reachable only from the family tunnel.
#
# WHY THIS EXISTS. The NixOS peers resolve the service names from
# `networking.hosts` (modules/family/vpn-peer.nix) -- a phone has no such file. It needs
# something to tell it that immich.luckyobserver.com is 10.41.0.1, and that answer has to
# be the same on home wifi, on cellular, and on a hotel network.
#
# The alternative was publishing A records for 10.41.0.1 in public DNS. That works, but it
# puts the internal addressing in front of anyone who asks, and a resolver with
# DNS-rebinding protection may strip a private answer from a public zone. Answering over
# the tunnel keeps it private and cannot be filtered by someone else's resolver.
#
# The side benefit is the real prize: with `DNS = 10.41.0.1` in the phone's WireGuard
# profile, EVERY lookup it makes goes through here and on to AdGuard on the router. The
# content filtering follows the phone onto cellular and onto other people's wifi, instead
# of stopping at the front door.
#
# Scope: bound to the wgfam address only. This is not a LAN resolver and must not become
# one -- the router is that, and two authorities for the same names is how split-horizon
# DNS starts lying to you.
{ config, lib, pkgs, ... }:
let
  peers = import ./peers.nix;
  fam = peers.hubs.fam;
  adm = peers.hubs.adm;
in
{
  services.dnsmasq = {
    enable = true;

    # Do NOT point this host's own resolver at dnsmasq. hydrogen resolves via
    # networking.nameservers (10.0.0.1) and should keep doing so: making the box depend
    # on a service that binds to a WireGuard interface means a tunnel problem becomes a
    # name-resolution problem for every service on it.
    resolveLocalQueries = false;

    settings = {
      # Bind the tunnel addresses and nothing else. bind-interfaces (rather than the
      # default wildcard bind) is what keeps this off br0.
      #
      # Both tunnels, because phones on either one need a resolver: the NixOS hosts use
      # networking.hosts and never ask anybody.
      interface = [ fam.interface adm.interface ];
      bind-interfaces = true;

      # The service names, answered authoritatively. Enumerated rather than wildcarded
      # for the same reason the router refuses to wildcard this zone: hub. and vpn. are
      # real public records pointing at the WAN address, and a wildcard would swallow
      # them -- including the endpoint a client needs to resolve to build the very
      # tunnel it is asking over.
      address = map (n: "/${n}/${fam.address}") peers.serviceNames
        # The router's own admin UIs, answered at its TUNNEL address rather than the
        # 10.0.0.1 the router's own resolver hands out. A phone with the tunnel up must
        # not route 10.0.0.1 into it -- that is its gateway whenever it is on home wifi.
        # Without the tunnel, at home, the router answers 10.0.0.1 itself and that is
        # correct; this entry only ever applies to clients already inside.
        ++ map (n: "/${n}/${peers.routerMgmt.address}") [ "kids.lan" "adguard.lan" ];

      # Everything else goes to the router, which is AdGuard Home. That is the whole
      # point: a phone on cellular gets the same filtering as a device at home.
      no-resolv = true;
      server = [ peers.lanGateway ];

      cache-size = 1000;
      domain-needed = true;   # don't forward bare names upstream
      bogus-priv = true;      # don't forward reverse lookups for private ranges

      # DNSSEC is deliberately off. The router already validates upstream, and the
      # `address=` answers above are locally synthesised and unsigned by construction --
      # validating here would only create a second place for it to go wrong.
    };
  };

  # dnsmasq binds specific addresses, so BOTH interfaces have to exist first. Without
  # this it starts, fails to bind, and stays down until something restarts it -- and
  # bind-interfaces makes that fatal rather than partial.
  #
  # wgadm was missing from this list until 2026-08-06 and the race simply had not been
  # lost yet: dnsmasq happened to start after both. A boot that ordered them the other
  # way would have left the admin tunnel with no resolver and no obvious reason why.
  systemd.services.dnsmasq = {
    after = [ "wireguard-${fam.interface}.service" "wireguard-${adm.interface}.service" ];
    wants = [ "wireguard-${fam.interface}.service" "wireguard-${adm.interface}.service" ];
  };

  # 53 on the two tunnels. Not on br0, not globally.
  networking.firewall.interfaces.${fam.interface} = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };
  networking.firewall.interfaces.${adm.interface} = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };
}
