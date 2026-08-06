# Family laptop. Everything that makes it one is modules/family/profile.nix; the peer
# address, WireGuard key, sops key names and Minecraft handle all follow from the
# hostname via modules/family/peers.nix.
#
# The hostname is the child's Minecraft handle, lowercased -- not their name. This
# repository is public; see the comment on `family` in modules/family/peers.nix.
{ ... }:

{
  imports = [
    ../hardware/gentlemenpupil.nix
    ../modules/family/profile.nix
  ];

  networking.hostName = "gentlemenpupil";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10; # Prevent ESP from filling
  boot.initrd.systemd.enable = true;

  system.stateVersion = "25.11";
}
