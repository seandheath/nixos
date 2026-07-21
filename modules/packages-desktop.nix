# Common desktop application set for workstation hosts. Extracted from
# workstation.nix; grouped by concern. DE-agnostic (works on any desktop).
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Screenshots
    flameshot

    # Document creation and processing
    tectonic
    pandoc
    recoll
    evince
    poppler-utils
    img2pdf
    exiftool

    # Communication and collaboration
    element-desktop
    signal-desktop
    discord
    thunderbird

    # Remote access
    moonlight-qt   # Moonlight client for hydrogen's Sunshine host
    rustdesk-flutter   # RustDesk (host on hydrogen, client on workstations); LAN direct-IP

    # Development tools
    hexo-cli
    gemini-cli
    git
    python3
    aider-chat
    gnumake
    nodejs
    gcc
    parallel
    zstd

    # 3D printing and CAD
    prusa-slicer
    openscad
    freecad
    kicad

    # Note-taking and productivity
    obsidian
    xournalpp

    # Multimedia
    mpv
    vlc
    pavucontrol
    freetube
    qbittorrent

    # System utilities
    keepassxc
    (appimage-run.override {
      extraPkgs = pkgs: [ pkgs.zstd ];
    })
    brasero
    ripgrep
    btop-cuda
    wget
    neovim
    zenity # terminal notifications
    p7zip
    sops
    age
    srm
    keyd
    evtest
    libinput
    mullvad-vpn
    wl-clipboard

    # Gaming
    # blightmud  # temporarily disabled - build failure with gcc 15
    (lutris.override {
      extraLibraries = pkgs: [
        libgudev
        libvdpau
        libtheora
        speex
      ];
    })
    protonup-ng
    protontricks
    #wine
    #wine64
    wineWow64Packages.waylandFull
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
    mullvad-browser

    # USB hardware tools (Great Scott Gadgets Cynthion)
    cynthion   # CLI/Python utilities for the Cynthion USB test instrument
    packetry   # USB 2.0 protocol analyzer GUI for Cynthion
  ];
}
