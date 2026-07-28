{
  isNormalUser = true;
  description = "sheath";
  # "input" is for direct evdev access to gamepads (hydrogen's couch-Minecraft
  # launcher reads /dev/input/pN under bubblewrap); harmless on the other hosts.
  extraGroups = [ "wheel" "networkmanager" "video" "input" "libvirtd" "podman" "scanner" "lp" "dialout" ];
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLhPOBx9dR2X3oYz5RS2eAGZA7YSeHPcnrQauHSmuk1"
  ];
  group = "sheath";
}
