# Registry of hydrogen's two WireGuard hubs and every peer on them.
#
# Imported by modules/family/vpn-hub.nix (hydrogen) and modules/family/vpn-peer.nix
# (everything else) so the two sides cannot drift: an address or public key appears
# exactly once, here.
#
# WHY TWO HUBS RATHER THAN ONE INTERFACE WITH CLEVER RULES. They carry different
# authority and that difference should be visible in `iptables -S`, not buried in a
# source-address match. `wgadm` reaches sshd, RustDesk and Syncthing; `wgfam` reaches
# a web server and a game port. One interface with both would mean every future rule
# has to remember which peers are which.
#
# Public keys are not secret -- they are what the *other* end needs to authenticate us,
# and they identify nobody. The private halves live in sops (`secret` below); which
# file each one is in follows the host's own sops.defaultSopsFile:
#   - family laptops   -> secrets/family.yaml  (family age key, see .sops.yaml)
#   - hydrogen/sulfur -> secrets/secrets.yaml (main age key)
#
# Regenerate everything with ./gen-family-secrets.sh; it prints exactly the public
# keys below.
rec {
  # Public endpoint for both hubs -- the SAME name the router's own hub uses.
  #
  # An earlier draft invented hub.luckyobserver.com to avoid a "collision" that does not
  # exist: a hostname is just an A record, and the three hubs are told apart by port
  # (51820 -> the router itself, 51821/51822 -> hydrogen via the router's forwardPorts).
  # Reusing vpn. means ddclient on the router already keeps it pointed at the current WAN
  # address, and there is no Cloudflare record to remember to create.
  #
  # It resolves to the WAN address on the LAN too: the router's split-horizon DNS answers
  # per-subdomain and deliberately never wildcards this zone, precisely to leave this
  # record alone. That is fine -- peers at home reach hydrogen by its LAN address instead,
  # which modules/family/wg-endpoint.nix tries first.
  endpointHost = "vpn.luckyobserver.com";

  # hydrogen's LAN address. Peers on the home network target this directly instead of
  # bouncing off the gateway -- see modules/family/wg-endpoint.nix.
  lanEndpoint = "10.0.0.10";
  lanSubnet = "10.0.0.0/24";

  # The router. modules/family/dns.nix forwards everything that is not one of our own
  # service names here, which is AdGuard Home -- so a phone using the tunnel's resolver
  # gets the household filtering wherever it happens to be.
  lanGateway = "10.0.0.1";

  hubs = {
    # Family tunnel: web services + Minecraft, nothing else. Peers are isolated from
    # each other and from the LAN by hydrogen's FORWARD policy.
    fam = {
      interface = "wgfam";
      port = 51821;
      subnet = "10.41.0.0/24";
      address = "10.41.0.1";
      publicKey = "ALwEaWzOtlZ7NspsMoFy9l9aTOG1bXdvXgmzf3xVc2Y=";
      secret = "wg-priv-wgfam-hub";
    };

    # Admin tunnel: sulfur only. SSH, RustDesk, Syncthing, plus the web services.
    adm = {
      interface = "wgadm";
      port = 51822;
      subnet = "10.42.0.0/24";
      address = "10.42.0.1";
      publicKey = "wxLQ7mv3IGFVecZnrtZ0LrqtEbHr5j/nh0yYHq4SXjs=";
      secret = "wg-priv-wgadm-hub";
    };
  };

  # The router's management tunnel (nixrouter modules/wireguard-mgmt.nix).
  #
  # sulfur peers with this DIRECTLY, not through hydrogen. Routing the router's
  # administration through hydrogen would make the thing everything depends on depend on
  # a service host; WireGuard has no hubs, only pairs, so sulfur simply holds two peer
  # relationships and neither outage implies the other.
  #
  # Peers address it at `address` (10.42.0.3), NEVER at lanAddress. lanAddress is only
  # the endpoint to dial when at home; putting it in a peer's allowedIPs routes the
  # client's own default gateway and resolver into the tunnel and takes its network out.
  # That is not hypothetical -- it happened to sulfur on 2026-08-06.
  routerMgmt = {
    address = "10.42.0.3";
    lanAddress = "10.0.0.1";
    port = 51823;
    publicKey = "/4/zGHCJN/J2IrGEprkcPk+35Mij+kzY2UxNK+8Y5Qs=";
    secret = "wg-priv-sulfur-adm";   # sulfur reuses its wgadm key for this peer
  };

  # wgadm peers -- sheath's own devices, and nothing else.
  #
  # sulfur's address is referenced by name in three places (the hub's FORWARD rule, the
  # laptops' allowedIPs, hydrogen's peer list) -- never retype it.
  #
  # Only entries with a `secret` are NixOS hosts that build their own wg config from it;
  # a phone carries its key on the device and needs nothing here but a public half.
  # Being on wgadm gives these devices network reach to sshd, RustDesk and Syncthing --
  # all key- or password-authenticated, but it is why this list is not the place for
  # anyone else's phone. Those go on wgfam under `mobile`.
  admin = {
    sulfur = {
      address = "10.42.0.2";
      publicKey = "B3JEHLQkYPzrbiJAlDcd7fi50j2egYo9enu257jvBSU=";
      secret = "wg-priv-sulfur-adm";
    };

    sheath-phone = {
      address = "10.42.0.4";
      publicKey = "3IB2mSQy5JlTNb/JR2717gzNHAoiqACLgIZBiIlGlHE=";
    };
  };

  # Family-tunnel peers.
  #
  # Every secret is named after the host that uses it -- `wg-priv-<host>` here, matching
  # the existing wg-priv-sulfur / wg-priv-fleet convention, and `<host>-password-hash`
  # in secrets/family.yaml, matching nextcloud-adminpass / paperless-adminpass. There is
  # no device numbering: an earlier draft keyed these as family-device-1..4 to keep names
  # out of a public repo, which the handles already do, so the number was a second
  # identifier to keep in step for nothing.
  #
  # Every peer here is a family laptop, so every secret is in secrets/family.yaml.
  #
  # Hostnames are the Minecraft handles from modules/minecraft-couch.nix, lowercased.
  # Deliberately not the kids' real names: this repository is public. The handles are
  # already committed there, identify nobody, and keep the login identity and the game
  # identity in step.
  #
  # `minecraftName` must match modules/minecraft-couch.nix's seedPlayers EXACTLY, case
  # included. An offline-mode UUID is a hash of the username, so a laptop that joins
  # under a different spelling is a different character with an empty inventory --
  # including "PhantomSpecialst", which is missing an `i` and has to stay that way.
  family = {
    gentlemenpupil = {
      address = "10.41.0.11";
      publicKey = "gZrsl4Mv8jvv+Dp37RUqWCIT5Owi4C9YXLhsZAAXZmw=";
      secret = "wg-priv-gentlemenpupil";
      minecraftName = "GentlemenPupil";
    };
    vizualwanderer = {
      address = "10.41.0.12";
      publicKey = "sHSgp24NhRsy7HW8gszTJKandRMw9mjjIBtdGsw+nAo=";
      secret = "wg-priv-vizualwanderer";
      minecraftName = "VizualWanderer";
    };
    phantomspecialst = {
      address = "10.41.0.13";
      publicKey = "kUX1m8dFnmIzPuXxKsVuqX3xuRWhNy9M1QpFeH3SYm0=";
      secret = "wg-priv-phantomspecialst";
      minecraftName = "PhantomSpecialst";
    };
    maddreamer = {
      address = "10.41.0.14";
      publicKey = "3sp3RatkKmc8WVawl0G4HG9D53NiG+qQyYxq4DWbNFY=";
      secret = "wg-priv-maddreamer";
      minecraftName = "MadDreamer";
    };

    # 10.41.0.3 was osmium and 10.41.0.4 was surface, both retired 2026-08-06. Left
    # unallocated rather than recycled -- an address that once meant a different machine
    # is a good way to misread a `wg show` later.
  };

  # Hand-configured wgfam peers: phones and tablets. Same tunnel and the same isolation
  # as the laptops, but nothing about them is NixOS-managed, so they carry no `secret`
  # (their private key is generated on the device and never enters this repo) and no
  # `minecraftName`.
  #
  # LEAVE ENTRIES OUT UNTIL YOU HAVE THE REAL PUBLIC KEY. `wg setconf` rejects a
  # malformed key and fails the whole interface, so a placeholder here does not merely
  # not-work -- it takes wgfam down for the four laptops too.
  #
  # To add one:
  #   1. Install WireGuard on the device and create a tunnel; it generates the keypair.
  #   2. Profile: Address 10.41.0.<n>/32, AllowedIPs 10.41.0.1/32,
  #      DNS 10.41.0.1, Endpoint hub.luckyobserver.com:51821, PersistentKeepalive 25.
  #   3. Paste the device's PUBLIC key below, rebuild hydrogen, switch.
  #
  # Reserved: .20 sheath's phone, .21 spouse's phone, .22+ tablets.
  mobile = {
    spouse-phone = {
      address = "10.41.0.21";
      publicKey = "PrXXMEAU1mVsZLz/0CLZ14mXYJqwEppaV5OUEr0c504=";
    };
  };


  # Service names every peer resolves to its hub's address. These are the vhosts in
  # modules/{nextcloud,immich,paperless,calibre}.nix; `mc` is Minecraft, which has no
  # vhost and exists only as a name for the kids to type.
  #
  # The names are unchanged from their public form on purpose -- the wildcard ACME cert
  # in modules/reverse-proxy.nix covers *.luckyobserver.com, so pointing them at a
  # tunnel address keeps TLS valid with no per-host certificate work.
  serviceNames = [
    "nc.luckyobserver.com"
    "immich.luckyobserver.com"
    "paper.luckyobserver.com"
    "calibre.luckyobserver.com"
    "mc.luckyobserver.com"
  ];
}
