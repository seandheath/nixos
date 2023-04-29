{ config, pkgs, ... }: {
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  environment.systemPackages = with pkgs; [
    pavucontrol
    firefox
    vlc
    jellyfin-media-player
    appimage-run
  ];
  services.xserver = {
    enable = true;
    desktopManager.kodi.enable = true;
    displayManager.autoLogin.enable = true;
    displayManager.autoLogin.user = "kodi";
    displayManager.lightdm.autoLogin.timeout = 3;
  };
  networking.firewall = {
    allowedTCPPorts = [ 8080 ];
    allowedUDPPorts = [ 8080 ];
  };
  users.users.kodi = {
    isNormalUser = true;
    extraGroups = [ "usenet" ];
  };
  sound.enable = true;
  hardware.pulseaudio.enable = true;
}
