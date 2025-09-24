{
  isNormalUser = true;
  description = "sheath";
  extraGroups = [ "wheel" "networkmanager" "video" "libvirtd" "podman" ];
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLhPOBx9dR2X3oYz5RS2eAGZA7YSeHPcnrQauHSmuk1"
  ];
  group = "sheath";
}