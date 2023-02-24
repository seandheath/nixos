{ config, pkgs, ... }:
{
  services.syncthing = {
    enable = true;
    user = "lo";
    group = "users";
    overrideDevices = false;
    overrideFolders = false;
  };
}
