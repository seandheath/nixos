{ config, pkgs, ... }: {
  services.xserver.enable = true;
  services.xserver.desktopManager.kodi.enable = true;
  services.xserver.displayManager.autoLogin.enable = true;
  services.xserver.displayManager.autoLogin.user = "kodi";
  services.xserver.displayManager.lightdm.autoLogin.timeout = 3;
  users.extraUsers.kodi.isNormalUser = true;
  users.extraUsers.kodi.extraGroups = [ "usenet" ];
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
}