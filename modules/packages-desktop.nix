# Common desktop application set for workstation hosts. Extracted from
# workstation.nix; grouped by concern. DE-agnostic (works on any desktop).
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    # Screenshots: gnome-shell's built-in area capture (see modules/dconf.nix).
    # flameshot was dropped -- unusable on GNOME Wayland.

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
    nextcloud-client

    # Remote access
    rustdesk-flutter   # RustDesk client for hydrogen (host); LAN direct-IP

    # Development tools
    hexo-cli
    # gemini-cli removed 2026-08-11: nixpkgs marks it for removal upstream -- Google
    # moved unpaid and AI Pro/Ultra tiers to Antigravity CLI, so the package is on its
    # way out of the tree rather than merely stale. packages/qwen-code.nix (a
    # gemini-cli fork) and aider-chat below cover the same ground.
    git
    python3
    aider-chat
    codex   # OpenAI Codex CLI; auth via `codex login`, config in ~/.codex
    gnumake
    nodejs
    gcc
    parallel
    zstd

    # Reverse engineering
    # NSA SRE suite; wrapper pins its own JDK, no system java needed. Provides
    # `ghidra` and `ghidra-analyzeHeadless` like the plain nixpkgs package, plus
    # the ReVa MCP server on localhost:8080 (see modules/workstation.nix).
    ghidra-reva
    imjtool  # Android/embedded firmware images (bootimg, sparse, UEFI, super.img)

    # 3D printing and CAD
    prusa-slicer
    openscad
    freecad
    kicad

    # Note-taking and productivity
    marktext
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
    (lutris.override {
      extraLibraries = pkgs: [
        libgudev
        libvdpau
        libtheora
        speex
      ];
    })
    protonup-ng
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
