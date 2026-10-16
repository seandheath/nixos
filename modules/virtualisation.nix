{ config, pkgs, lib, ... }:{
  programs.virt-manager.enable = true;
  users.groups.libvirtd.members = [config.fleet.adminUser];
  users.groups.podman.members = [config.fleet.adminUser];
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
  # /var/tmp sits on the tmpfs root; multi-GB image loads overflow it. Stage in the
  # on-disk container storage instead.
  virtualisation.containers.containersConf.settings.engine.image_copy_tmp_dir = "storage";
  # Podman uses but never creates <graphroot>/tmp; root's already exists.
  systemd.user.tmpfiles.rules = [ "d %h/.local/share/containers/storage/tmp 0700 - - -" ];
  environment.systemPackages = with pkgs; [
    dive 
    podman-tui 
    podman-compose
  ];
}
