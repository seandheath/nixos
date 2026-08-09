# Keep NetworkManager's hands off every WireGuard interface this host declares.
#
# THE BUG THIS EXISTS TO PREVENT. NetworkManager has managed WireGuard devices since 1.16,
# so a tunnel created by wg-quick or by networking.wireguard still shows up as a device NM
# believes it owns -- and, on a GNOME box, as a toggle in the network panel. Switching that
# toggle off, or NM simply deciding the device has no matching connection profile,
# DEACTIVATES it: the address and every route are flushed. The systemd unit that built the
# tunnel is never told, and stays `active (exited)`.
#
# The result is a tunnel that is convincingly alive and completely useless. Observed on
# sulfur 2026-08-09: wgadm carried no address and no 10.41/10.42 routes, yet its unit read
# active and `wg show` reported recent handshakes for BOTH peers. The handshakes are not a
# contradiction and this is the part worth remembering -- keepalives are sent to the peer's
# endpoint over the UNDERLYING default route and never touch the tunnel's own address, so
# they keep succeeding on an interface that can carry no traffic at all. Nothing logs,
# nothing fails, and every service on the far side is quietly unreachable.
#
# WHY BOTH ATTRSETS. The first version of this read networking.wg-quick.interfaces only,
# which covered sulfur and the kids' laptops and missed the machine that matters most:
# hydrogen builds its two hubs with networking.wireguard.interfaces (modules/family/vpn-hub.nix),
# runs GNOME for RustDesk, and therefore had NM enabled with an empty unmanaged list. A flush
# there does not cost one laptop its tunnel -- it drops wgadm and wgfam, which is every family
# device at once. hydrogen never roaming is no protection: the exposure comes from NM managing
# the device at all, not from changing networks.
#
# WHY IT IS DERIVED RATHER THAN LISTED. A tunnel added later is covered without anyone
# remembering this file exists. It also self-adjusts in the other direction: an interface that
# moves to a real NM profile (see networking.networkmanager.ensureProfiles in hosts/sulfur.nix)
# leaves both attrsets and correctly drops off this list, because there NM ownership is the
# point -- a profile NM owns can be toggled safely, since deactivating tears the tunnel down
# and activating rebuilds it from config it actually holds.
#
# Imported for every host via commonModules in flake.nix. On a host without NetworkManager
# this option is simply inert.
{ config, lib, ... }:
{
  networking.networkmanager.unmanaged = map (n: "interface-name:${n}") (
    lib.attrNames config.networking.wg-quick.interfaces
    ++ lib.attrNames config.networking.wireguard.interfaces
  );
}
