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
    displayManager.kodi.enable = true;
    displayManager.autoLogin.enable = true;
    displayManager.autoLogin.user = "kodi";
    displayManager.lightdm.autoLogin.timeout = 3;
  };
  users.users.kodi = {
    isNormalUser = true;
    extraGroups = [ "usenet" ];
  };
  services.printing.enable = true;
  services.printing.drivers = with pkgs; [
    gutenprint
    gutenprintBin
    brlaser
    brgenml1lpr
  ];
  sound.enable = true;
  hardware.pulseaudio.enable = true;
  home-manager.users.luckyobserver = {
    imports = [
      ../home/gnome.nix
    ];
  };
  virtualisation = {
    oci-containers.backend = "podman";
    podman.enable = true;
    podman.dockerCompat = true;
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };
}
