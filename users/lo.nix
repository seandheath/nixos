{ config, pkgs, ... }:
{
  users.users.lo = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "libvirtd" "video" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLhPOBx9dR2X3oYz5RS2eAGZA7YSeHPcnrQauHSmuk1"
    ];
  };
}

