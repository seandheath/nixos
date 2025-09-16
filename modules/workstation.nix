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
    srm
    
    # Gaming
    blightmud
    (lutris.override {
      extraLibraries = pkgs: [
        libgudev
        libvdpau
        libtheora
        speex
      ];
    })
    protonup
    protontricks 
    #wine
    #wine64
    wineWowPackages.waylandFull
    winetricks
    vulkan-loader
    vulkan-tools
    ffmpeg-full
    gst_all_1.gstreamer
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good  
    gst_all_1.gst-plugins-bad
    gst_all_1.gst-plugins-ugly
    gst_all_1.gst-libav
    
    # Office suite
    libreoffice-fresh
    
    # Web browser
    google-chrome
    firefox
    mullvad-browser
  ];

  # Programs
  programs.firefox.enable = true;
  
  # Services
  services.mullvad-vpn.enable = true;
  services.mullvad-vpn.package = pkgs.mullvad-vpn;
  services.printing.enable = true;
  services.flatpak.enable = true;
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  
  # Wayland support for Electron apps
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  environment.sessionVariables.GST_PLUGIN_SYSTEM_PATH_1_0 = "/run/current-system/sw/lib/gstreamer-1.0";
  environment.sessionVariables.LD_LIBRARY_PATH = "/run/current-system/sw/lib";
}
