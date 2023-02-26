{ config, pkgs, ... }: {
  services.xserver.enable = true;
  services.xserver.desktopManager.kodi.enable = true;
  services.xserver.displayManager.autoLogin.enable = true;
  services.xserver.displayManager.user = "kodi";
  services.xserver.displayManager.lightdm.autoLogin.timeout = 3;
  users.extraUsers.kodi.isNormalUser = true;
  users.extraUsers.kodi.extragroups = [ "usenet" ];
}