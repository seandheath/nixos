{ config, pkgs, ... }:
{
  services.syncthing = {
    enable = true;
    user = "lo";
    dataDir = "/home/lo";
    configDir = "/home/lo/.config/syncthing";
    guiAddress = "127.0.0.1:8384";
  };
}
