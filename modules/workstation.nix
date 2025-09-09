{ config, pkgs, lib, ... }: {
  # Common workstation applications that work with any desktop environment
  environment.systemPackages = with pkgs; [
    # Document creation and processing
    tectonic
    pandoc
    
    # Communication and collaboration
    element-desktop
    signal-desktop
    discord
    thunderbird
    
    # Development tools
    hexo-cli
    vscodium
    gemini-cli 
    claude-code 
    git
    python3
    vscode
    
    # 3D printing and CAD
    prusa-slicer
    openscad
    
    # Note-taking and productivity
    obsidian 
    xournalpp
    
    # Multimedia
    vlc
    pavucontrol
    
    # System utilities
    keepassxc
    appimage-run
    brasero
    ripgrep
    btop-cuda
    wget
    neovim
    toybox # utilities like strings
    zenity # terminal notifications
    p7zip
    sops
    age
    
    # Gaming
    blightmud
    lutris
    wine
    wine64
    wine-wayland
    winetricks
    protontricks 
    wineWowPackages.waylandFull 
    wineWowPackages.staging
    protonup
    
    # Office suite
    libreoffice-fresh
    
    # Web browser
    google-chrome
    firefox
    mullvad-browser
  ];

  # Programs
  programs.gamescope.enable = true;
  programs.gamemode.enable = true;
  programs.steam.enable = true;
  programs.firefox.enable = true;
  
  # Services
  services.mullvad-vpn.enable = true;
  services.mullvad-vpn.package = pkgs.mullvad-vpn;
  services.printing.enable = true;
  services.flatpak.enable = true;
  
  # Wayland support for Electron apps
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
}