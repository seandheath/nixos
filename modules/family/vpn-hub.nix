# hydrogen's two WireGuard hubs. Imported only by hosts/hydrogen.nix.
#
# WHAT CHANGED AND WHY. Until now hydrogen had no WireGuard interface at all: the only
# hub lived on the router (vpn.luckyobserver.com:51820, 10.40.0.0/24) and forwarded to
# hydrogen's LAN address, so tunnel traffic ingressed on br0 indistinguishably from LAN
# traffic. Every service rule was therefore scoped to br0, which made network location
# the authorisation -- anyone on the home wifi had exactly the access an enrolled peer
# had. modules/minecraft-server.nix spells out the worst case: that server verifies no
# identity, so reachability IS authentication, and "reachable" meant "on the wifi".
#
# These two hubs move the boundary to key possession. The port lists live in
# hosts/hydrogen.nix so that "which port is open where" reads as one table; what lives
# here is the interfaces themselves and the forwarding policy between them.
#
# The router hub is deliberately NOT retired. It still reaches the LAN, and 22 is still
# open on br0, so a broken wgadm config or a failed sops decrypt does not cost you
# access to the box. It gets no path to the services.
{ config, lib, ... }:
let
  peers = import ./peers.nix;
  fam = peers.hubs.fam;
  adm = peers.hubs.adm;

  # /32 per peer: WireGuard's allowedIPs is a crypto-routing table, not an ACL, but on
  # the hub side it does double duty -- a peer may only *source* packets from an address
  # listed against its own key, so a kid's laptop cannot spoof a sibling's address.
  mkPeer = p: {
    inherit (p) publicKey;
    allowedIPs = [ "${p.address}/32" ];
  };

  sulfurAddr = peers.admin.sulfur.address;

  # Forward policy, in order. Everything about the isolation guarantee is these four
  # rules; read them top to bottom.
  #
  # The peers' own allowedIPs already stop them addressing anything but the hub, but
  # that is the *client's* configuration and a family laptop is a machine a child has
  # physical access to. These rules are the half of the boundary that is enforced here.
  forwardRules = [
    # sulfur administers the family laptops over SSH, and nothing else crosses.
    "-i ${adm.interface} -o ${fam.interface} -s ${sulfurAddr} -p tcp --dport 22 -j ACCEPT"
    # ...and their replies get back.
    "-i ${fam.interface} -o ${adm.interface} -m state --state ESTABLISHED,RELATED -j ACCEPT"
    # No family peer reaches the LAN, the router's admin page at 10.0.0.2, or a sibling.
    "-i ${fam.interface} -j DROP"
    # Nothing reaches a family peer unsolicited either, from any direction.
    "-o ${fam.interface} -j DROP"
  ];

  # A DEDICATED CHAIN, rebuilt as a unit -- not four independent rules appended to
  # FORWARD.
  #
  # The first version did delete-then-append per rule, and on the very first switch
  # hydrogen came up with `-i wgfam -j DROP` absent while the other three were present.
  # That is the rule that stops a family peer forwarding onto the LAN, and FORWARD's
  # policy is ACCEPT, so a partial application is not a degraded boundary -- it is no
  # boundary. Four statements that must each land, in order, in a chain libvirtd also
  # edits, is too many places for that to go wrong silently.
  #
  # Flushing our own chain and refilling it means the rule set is either entirely
  # present or entirely absent, the order is guaranteed by construction, and a reload
  # cannot stack duplicates. The jump is inserted at position 1 so it is evaluated
  # before anything libvirt puts there.
  chain = "family-forward";

  addRules = ''
    iptables -N ${chain} 2>/dev/null || true
    iptables -F ${chain}
    ${lib.concatMapStringsSep "\n    " (r: "iptables -A ${chain} ${r}") forwardRules}
    iptables -C FORWARD -j ${chain} 2>/dev/null || iptables -I FORWARD 1 -j ${chain}
  '';

  delRules = ''
    iptables -D FORWARD -j ${chain} 2>/dev/null || true
    iptables -F ${chain} 2>/dev/null || true
    iptables -X ${chain} 2>/dev/null || true
  '';
in
{
  sops.secrets.${fam.secret} = { };
  sops.secrets.${adm.secret} = { };

  networking.wireguard.interfaces = {
    ${fam.interface} = {
      ips = [ "${fam.address}/24" ];
      listenPort = fam.port;
      privateKeyFile = config.sops.secrets.${fam.secret}.path;
      peers = map mkPeer (lib.attrValues peers.family);
    };

    ${adm.interface} = {
      ips = [ "${adm.address}/24" ];
      listenPort = adm.port;
      privateKeyFile = config.sops.secrets.${adm.secret}.path;
      peers = map mkPeer (lib.attrValues peers.admin);
    };
  };

  # Stated rather than inherited. libvirtd already turns this on as a side effect of
  # its NAT network, which means the sulfur -> laptop SSH path would work by accident
  # today and break the day libvirtd is disabled. It is a dependency; say so.
  boot.kernel.sysctl."net.ipv4.ip_forward" = true;

  # Replies from a peer arrive on the tunnel while the route back may point elsewhere;
  # strict rp_filter drops them. mkDefault because modules/fleet-vpn.nix sets the same
  # value and hosts/sulfur.nix sets it outright.
  networking.firewall.checkReversePath = lib.mkDefault "loose";

  networking.firewall.extraCommands = addRules;
  networking.firewall.extraStopCommands = delRules;

  # NEITHER INTERFACE MAY BE ADDED TO networking.firewall.trustedInterfaces. Doing so
  # accepts everything arriving on it regardless of the port lists in hosts/hydrogen.nix,
  # which would hand every family peer the whole box.
}
