{ config, pkgs, ... }:
{
  services.syncthing = {
    enable = true;
    user = "lo";
    group = "users";
    dataDir = "/home/lo";
    guiAddress = "127.0.0.1:8384";
  };
}
