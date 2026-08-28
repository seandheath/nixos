# Registry of hydrogen's two WireGuard hubs and every peer on them. Imported by
# vpn-hub.nix (hydrogen) and vpn-peer.nix (everything else), so an address or public key
# appears exactly once. Also read by install.sh via `nix eval --file`.
#
# Two hubs rather than one interface with source-address rules: they carry different
# authority, and that should be visible in `iptables -S`. wgadm reaches sshd, RustDesk and
# Syncthing; wgfam reaches a web server and a game port.
#
# Public keys are not secret. The private halves live in sops under `secret`, in the file
# the host's own sops.defaultSopsFile names -- family.yaml for the laptops, secrets.yaml
# for hydrogen and sulfur; edit them with `sops secrets/<file>.yaml`.
rec {
  # Publicly both are DNS-only CNAMEs to the dynamic WAN record. The router provides
  # split-horizon answers at home, so clients reach the owning device directly without
  # hairpin NAT or an endpoint-selection service.
  hydrogenEndpointHost = "hydrogen.luckyobserver.com";
  routerEndpointHost = "router.luckyobserver.com";
  lanSubnet = "10.0.0.0/24";

  hubs = {
    # Family tunnel: web services + Minecraft, nothing else. Peers are isolated from
    # each other and from the LAN by hydrogen's FORWARD policy.
    fam = {
      interface = "wgfam";
      port = 51821;
      subnet = "10.41.0.0/24";
      address = "10.41.0.2";
      publicKey = "ALwEaWzOtlZ7NspsMoFy9l9aTOG1bXdvXgmzf3xVc2Y=";
      secret = "wg-priv-wgfam-hub";
    };

    # Admin tunnel: sulfur only. SSH, RustDesk, Syncthing, plus the web services.
    adm = {
      interface = "wgadm";
      port = 51822;
      subnet = "10.42.0.0/24";
      address = "10.42.0.2";
      publicKey = "wxLQ7mv3IGFVecZnrtZ0LrqtEbHr5j/nh0yYHq4SXjs=";
      secret = "wg-priv-wgadm-hub";
    };
  };

  # The router's management tunnel (nixrouter). sulfur peers with it directly, not through
  # hydrogen -- the thing everything depends on should not depend on a service host.
  #
  # Peers address it at `address`, NEVER at lanAddress: lanAddress is only the endpoint to
  # dial when at home, and putting it in allowedIPs routes the client's own gateway and
  # resolver into the tunnel. That took sulfur's network out on 2026-08-06.
  routerMgmt = {
    address = "10.42.0.1";
    lanAddress = "10.0.0.1";
    port = 51823;
    publicKey = "/4/zGHCJN/J2IrGEprkcPk+35Mij+kzY2UxNK+8Y5Qs=";
    secret = "wg-priv-sulfur-adm";   # sulfur reuses its wgadm key for this peer
  };

  # wgadm peers -- sheath's own devices only, because wgadm reaches sshd, RustDesk and
  # Syncthing. Anyone else's phone goes on wgfam under `mobile`. Only entries with a
  # `secret` are NixOS hosts; a phone carries its key on the device.
  admin = {
    sulfur = {
      address = "10.42.0.3";
      publicKey = "B3JEHLQkYPzrbiJAlDcd7fi50j2egYo9enu257jvBSU=";
      secret = "wg-priv-sulfur-adm";
    };

    sheath-phone = {
      address = "10.42.0.4";
      publicKey = "T1JupspOSEWuBKZrPuwSWy7Hdo9vu84grjU3f7jEQmQ=";
    };
  };

  # Family laptops. Hostnames are the Minecraft handles lowercased -- this repository is
  # public, so not the kids' real names -- and every secret is in secrets/family.yaml.
  #
  # `minecraftName` must match minecraft-couch.nix's seedPlayers EXACTLY, case included: an
  # offline-mode UUID is a hash of the username, so a different spelling is a different
  # character with an empty inventory. That includes "PhantomSpecialst", which is missing an
  # `i` and has to stay that way.
  family = {
    gentlemenpupil = {
      address = "10.41.0.11";
      publicKey = "gZrsl4Mv8jvv+Dp37RUqWCIT5Owi4C9YXLhsZAAXZmw=";
      secret = "wg-priv-gentlemenpupil";
      minecraftName = "GentlemenPupil";
      minecraftControlPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINx5O4lDxrgv+vuUWV+egyuDgA9uZxHUxryaYgs47t4g minecraft-control-gentlemenpupil";
    };
    vizualwanderer = {
      address = "10.41.0.12";
      publicKey = "sHSgp24NhRsy7HW8gszTJKandRMw9mjjIBtdGsw+nAo=";
      secret = "wg-priv-vizualwanderer";
      minecraftName = "VizualWanderer";
      minecraftControlPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICK5Z+OSkuNZnZkp5dXcCdHp2ZEkLOKJGbRM5juheISE minecraft-control-vizualwanderer";
    };
    phantomspecialst = {
      address = "10.41.0.13";
      publicKey = "kUX1m8dFnmIzPuXxKsVuqX3xuRWhNy9M1QpFeH3SYm0=";
      secret = "wg-priv-phantomspecialst";
      minecraftName = "PhantomSpecialst";
      minecraftControlPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ01Mzc22w/nGvjE3yLEBtZLmQnQU1+XJ6VsANnZn5mn minecraft-control-phantomspecialst";
    };
    maddreamer = {
      address = "10.41.0.14";
      publicKey = "3sp3RatkKmc8WVawl0G4HG9D53NiG+qQyYxq4DWbNFY=";
      secret = "wg-priv-maddreamer";
      minecraftName = "MadDreamer";
      minecraftControlPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINTSY6wbOWuWg92tG5asAREtGwU4NyH+YIpz9fONdlEk minecraft-control-maddreamer";
    };

    # .3 and .4 are retired hosts, left unallocated rather than recycled -- a reused address
    # is a good way to misread a `wg show` later.
  };

  # Phones and tablets: same tunnel and isolation as the laptops, but nothing here is
  # NixOS-managed, so no `secret` and no `minecraftName` -- the device generates its own
  # keypair and only the public half is pasted here.
  #
  # To enrol one: create a tunnel in the WireGuard app (it generates the keypair), set
  #   Address     10.41.0.<n>/32
  #   AllowedIPs  <hubs.fam.address>/32, <routerMgmt.address>/32
  #   DNS         <routerMgmt.address>, 1.1.1.1
  #   Endpoint    <hydrogenEndpointHost>:<hubs.fam.port>
  #   PersistentKeepalive 25
  # then add its public key below and rebuild hydrogen. The second DNS server is not
  # optional -- with only the tunnel resolver listed, a phone that roams off the tunnel
  # resolves nothing at all.
  #
  # LEAVE AN ENTRY OUT UNTIL YOU HAVE THE REAL PUBLIC KEY -- `wg setconf` rejects a
  # malformed key and fails the whole interface, taking wgfam down for the laptops too.
  #
  # Reserved: .20 sheath's phone, .21 spouse's phone, .22+ tablets.
  mobile = {
    spouse-phone = {
      address = "10.41.0.21";
      publicKey = "PrXXMEAU1mVsZLz/0CLZ14mXYJqwEppaV5OUEr0c504=";
    };
  };

  # People outside the household, here for Minecraft. Separate from `mobile` -- the
  # isolation is identical, but who holds the key is what a reader needs to see at a glance.
  #
  # A guest key reaches more than the name suggests: wgfam's firewall list is per-INTERFACE,
  # so it reaches 80/443 as well as 25565. Those are password-authenticated, so what becomes
  # reachable is a login page. Accepted; if that changes, the answer is a third hub carrying
  # only 25565, not a source-address rule.
  #
  # No minecraftName: they type their own username, and it must not collide with a handle in
  # `family` -- a collision does not clash, it lands them in that child's character.
  guests = {
    brother-laptop = {
      address = "10.41.0.30";
      publicKey = "UvmwoRJlvWncUI9ldgh3r1xG48kmz0N6Nv1c5MNr9mw=";
    };
  };


  # THE ROUTER IS THE ONLY RESOLVER: hydrogen briefly ran a second dnsmasq for this zone,
  # which is how split-horizon DNS starts giving two answers to one question. This feeds the
  # NixOS hosts' networking.hosts; the router keeps its own copy and the two are kept in
  # step by hand. Phones set DNS to routerMgmt.address instead.
  #
  # An assertion in reverse-proxy.nix ties every fleet.vhosts entry to this list. `mc` has
  # no vhost -- it is a name for the kids to type. The names keep their public form so the
  # wildcard ACME cert still matches when they point at a tunnel address.
  serviceNames = [
    "nc.luckyobserver.com"
    "immich.luckyobserver.com"
    "paper.luckyobserver.com"
    "calibre.luckyobserver.com"
    "mc.luckyobserver.com"
  ];
}
