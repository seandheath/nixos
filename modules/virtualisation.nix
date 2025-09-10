{ config, pkgs, lib, ... }:{
  programs.virt-manager.enable = true;
  users.users.sheath = {
    subUidRanges = [{ startUid = 100000; count = 65536; }];
    subGidRanges = [{ startGid = 100000; count = 65536; }];
  };
  users.groups.libvirtd.members = ["sheath"];
  users.groups.podman.members = ["sheath"];
  virtualisation.libvirtd.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;
  virtualisation.podman = {
    enable = true;
    autoPrune.enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  environment.systemPackages = with pkgs; [
    dive 
    podman-tui 
    podman-compose
    fuse-overlayfs
  ];
}
