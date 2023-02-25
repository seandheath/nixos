{ config, pkgs, ... }:
{
  services.syncthing = {
    enable = true;
    user = "lo";
    group = "users";
  };
}
