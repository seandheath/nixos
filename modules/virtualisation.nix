{ config, pkgs, lib, ... }:{
  programs.virt-manager.enable = true;
  users.groups.libvirtd.members = ["sheath"];
  users.groups.podman.members = ["sheath"];
  virtualisation.libvirtd = {
    enable = true;
    qemu.swtpm.enable = true;
    # OpenSSH rejects libvirt's proxy snippet because its Nix-store path is owned by
    # nobody:nogroup, aborting every SSH invocation before it opens a connection. We do
    # not use the libvirt "qemu+ssh" host aliases, so keep the broken global include out
    # of /etc/ssh/ssh_config.
    sshProxy = false;
  };
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
  ];
}
