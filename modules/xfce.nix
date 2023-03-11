{ config, pkgs, lib, ... }:
{
  # Desktop Environment
  services.xserver = {
    enable = true;
    desktopManager.xfce.enable = true;
    displayManager.defaultSession = "xfce";
  };
  systemd.services.NetworkManager-wait-online.enable = false;
  environment.systemPackages = with pkgs; [
    p7zip
    openssl
    vlc
    jellyfin-media-player
  ];
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
}

