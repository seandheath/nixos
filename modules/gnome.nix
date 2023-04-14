{ config, pkgs, ... }:
let
  home-manager = builtins.fetchTarball "https://github.com/nix-community/home-manager/archive/master.tar.gz";
in {
  imports = [
    (import "${home-manager}/nixos")
  ];
  environment.systemPackages = with pkgs; [
    gopls
    go
    rustup
    teams
    alacritty
    pavucontrol
    firefox
    gnomeExtensions.appindicator
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnome.gnome-tweaks
    vlc
    jellyfin-media-player
    wireshark
    graphviz
    filezilla
    joplin-desktop
    virt-manager
    kicad
    nextcloud-client
    libreoffice
    vscodium
    keepassxc
    brasero
    signal-desktop
    discord
    protonvpn-gui
    appimage-run
    pandoc
    tectonic
    realesrgan-ncnn-vulkan
  ];
  environment.gnome.excludePackages = with pkgs; [
    gnome.cheese
    gnome.gnome-music
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome.epiphany
    gnome-tour
    evolution
  ];
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    layout = "us";
    xkbVariant = "";
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
