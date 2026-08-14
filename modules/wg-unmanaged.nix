# Keep NetworkManager's hands off every WireGuard interface this host declares, and set the
# reverse-path policy tunnels need. Imported for every host; inert where neither applies.
#
# NM has managed WireGuard devices since 1.16, so a tunnel built by wg-quick or
# networking.wireguard is a device NM believes it owns -- and on GNOME, a toggle. Switching
# that off, or NM deciding the device has no matching profile, flushes the address and every
# route while the systemd unit stays `active (exited)`. `wg show` still reports handshakes,
# because keepalives go to the peer's endpoint over the underlying default route and never
# touch the tunnel's own address. See CHANGELOG 2026-08-09.
#
# Derived rather than listed, so a tunnel added later is covered and one that moves to a real
# NM profile correctly drops off -- there, NM ownership is the point.
{ config, lib, ... }:
let
  # Tunnels systemd owns. Only these go on the unmanaged list.
  systemdOwned =
    lib.attrNames config.networking.wg-quick.interfaces
    ++ lib.attrNames config.networking.wireguard.interfaces;

  # Tunnels NM owns are deliberately NOT unmanaged, but still need the RPF policy.
  nmOwned = lib.filter
    (p: (p.connection.type or null) == "wireguard")
    (lib.attrValues config.networking.networkmanager.ensureProfiles.profiles);
in
{
  networking.networkmanager.unmanaged = map (n: "interface-name:${n}") systemdOwned;

  # Replies arriving on a tunnel are asymmetric to strict RPF and get dropped.
  networking.firewall.checkReversePath =
    lib.mkIf (systemdOwned != [ ] || nmOwned != [ ]) (lib.mkDefault "loose");
}
