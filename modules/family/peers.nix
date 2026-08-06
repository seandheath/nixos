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
  # Public endpoint for both hubs. A Cloudflare CNAME to vpn.luckyobserver.com, so it
  # inherits the router's dynamic DNS without the hydrogen hubs colliding with the
  # router hub's own use of the `vpn.` name (that one is still 51820 -> the router).
  endpointHost = "hub.luckyobserver.com";

  # hydrogen's LAN address. Peers on the home network target this directly instead of
  # bouncing off the gateway -- see modules/family/wg-endpoint.nix.
  lanEndpoint = "10.0.0.10";
  lanSubnet = "10.0.0.0/24";
  # Address prefix used to spot "we might be at home" before probing. Kept alongside
  # lanSubnet rather than derived from it: string-slicing a CIDR in Nix is more code
  # than the duplication is worth, and the two only ever change together.
  lanPrefix = "10.0.0.";

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

  # The one admin peer. Its address is referenced by name in three places (the hub's
  # FORWARD rule, the laptops' allowedIPs, hydrogen's peer list) -- never retype it.
  admin = {
    sulfur = {
      address = "10.42.0.2";
      publicKey = "B3JEHLQkYPzrbiJAlDcd7fi50j2egYo9enu257jvBSU=";
      secret = "wg-priv-sulfur-adm";
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

  # 10.41.0.20+ is reserved for phones and tablets. Add them here with a public key
  # and they are peers like any other; their private key never has to enter this repo
  # (generate on the device, paste the public half).

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
