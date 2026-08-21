# hydrogen's two WireGuard hubs, moving the access boundary from network location to key
# possession. The port lists live in hosts/hydrogen.nix so "which port is open where" reads
# as one table; this file owns the interfaces and the forwarding policy between them.
#
# The router's own hub is deliberately not retired -- it still reaches the LAN, so a broken
# wgadm config does not cost access to the box. It gets no path to the services.
{ config, lib, ... }:
let
  peers = import ./peers.nix;
  fam = peers.hubs.fam;
  adm = peers.hubs.adm;

  # /32 per peer: allowedIPs is a crypto-routing table, but on the hub side it also bounds
  # what a peer may SOURCE, so one laptop cannot spoof a sibling's address.
  mkPeer = p: {
    inherit (p) publicKey;
    allowedIPs = [ "${p.address}/32" ];
  };

  sulfurAddr = peers.admin.sulfur.address;

  # The isolation guarantee, in order. The peers' own allowedIPs already stop them
  # addressing anything else, but that is the CLIENT's config on a machine a child has
  # physical access to. This is the half enforced here.
  forwardRules = [
    # sulfur administers the family laptops over SSH, and nothing else crosses.
    "-i ${adm.interface} -o ${fam.interface} -s ${sulfurAddr} -p tcp --dport 22 -j ACCEPT"
    # ...and their replies get back.
    "-i ${fam.interface} -o ${adm.interface} -m state --state ESTABLISHED,RELATED -j ACCEPT"
    # No family peer reaches the LAN, the router's admin page at 10.0.0.2, or a sibling.
    "-i ${fam.interface} -j DROP"
    # Nothing reaches a family peer unsolicited either, from any direction.
    "-o ${fam.interface} -j DROP"
    # Nothing on the admin tunnel reaches the LAN: sulfur peers with the router directly.
    # FORWARD's policy is ACCEPT, so without this a client that widened its own allowedIPs
    # would quietly get the whole LAN.
    "-i ${adm.interface} -o br0 -j DROP"
  ];

  # A dedicated chain rebuilt as a unit, not rules appended to FORWARD: the per-rule
  # delete-then-append version once came up missing `-i wgfam -j DROP` while the rest
  # applied, and with FORWARD's ACCEPT policy a partial application is no boundary at all.
  # Flush-and-refill makes it all-or-nothing, ordered by construction, and safe to reload.
  # Inserted at position 1 so it beats anything libvirt adds.
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
      # Laptops, household devices and guests are the same kind of peer here -- one /32, one
      # key, the same isolation. They are separate attrsets because they differ in whose
      # hands the private key is in, which this file does not act on.
      peers = map mkPeer (
        lib.attrValues peers.family
        ++ lib.attrValues peers.mobile
        ++ lib.attrValues peers.guests
      );
    };

    ${adm.interface} = {
      ips = [ "${adm.address}/24" ];
      listenPort = adm.port;
      privateKeyFile = config.sops.secrets.${adm.secret}.path;
      peers = map mkPeer (lib.attrValues peers.admin);
    };
  };

  # Stated, not inherited: libvirtd turns this on as a side effect, so the sulfur -> laptop
  # SSH path would work by accident today and break the day libvirtd is disabled.
  boot.kernel.sysctl."net.ipv4.ip_forward" = true;


  networking.firewall.extraCommands = addRules;
  networking.firewall.extraStopCommands = delRules;

  # NEITHER INTERFACE MAY GO IN networking.firewall.trustedInterfaces -- that accepts
  # everything regardless of the port lists, handing every family peer the whole box.
}
