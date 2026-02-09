{ config, pkgs, lib, ... }: {
  imports = [ 
    ../modules/gnome.nix
    ../modules/sops.nix
    ../modules/dconf.nix
    ../modules/syncthing.nix
    ../modules/auto-update.nix
  ];
  nixpkgs.config.allowUnfree = true;
  # Common workstation applications that work with any desktop environment
  environment.systemPackages = with pkgs; [
    # Document creation and processing
    tectonic
    pandoc
    recoll
    evince
    
    # Communication and collaboration
    element-desktop
    signal-desktop
    discord
    thunderbird
    
    # Development tools
    hexo-cli
    # gemini-cli  # temporarily disabled - broken npm cache in nixpkgs
    claude-code 
    git
    python3
    vscode
    aider-chat
    gnumake
    nodejs
    gcc
    parallel
    zstd
    
    # 3D printing and CAD
    prusa-slicer
    openscad
    
    # Note-taking and productivity
    obsidian 
    xournalpp
    
    # Multimedia
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
    mullvad-browser
  ];

  # Programs
  programs.firefox.enable = true;

  # nix-ld for running dynamically linked executables (AppImages, etc.)
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      zstd
      stdenv.cc.cc.lib
      zlib
      glib
      libGL
      libx11
      libxcursor
      libxrandr
      libxi
      libxkbcommon
      wayland
      fontconfig
      freetype
      dbus
    ];
  };
  
  # Services
  services.mullvad-vpn.enable = true;
  services.printing.enable = true;
  services.printing.drivers = [ pkgs.epson-escpr2 ];

  # Avahi for network printer discovery (.local hostname resolution)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  services.flatpak.enable = true;
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;

  # Bluetooth
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true;  # Needed for battery reporting and better codec support
      };
    };
  };
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # Low-latency configuration for gaming
    extraConfig.pipewire."10-low-latency" = {
      "context.properties" = {
        "default.clock.rate" = 48000;
        "default.clock.quantum" = 256;
        "default.clock.min-quantum" = 256;
        "default.clock.max-quantum" = 512;
      };
    };
    # Bluetooth configuration for stable profile switching
    wireplumber.extraConfig."10-bluez" = {
      "monitor.bluez.properties" = {
        "bluez5.enable-sbc-xq" = true;
        "bluez5.enable-msbc" = true;
        "bluez5.enable-hw-volume" = true;
        "bluez5.roles" = [ "a2dp_sink" "a2dp_source" "bap_sink" "bap_source" "hsp_hs" "hsp_ag" "hfp_hf" "hfp_ag" ];
      };
    };
    # Disable auto-switching which can cause instability
    wireplumber.extraConfig."11-bluetooth-policy" = {
      "wireplumber.settings" = {
        "bluetooth.autoswitch-to-headset-profile" = false;
      };
    };
  };
  
  # Wayland support for Electron apps
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  #environment.sessionVariables.GST_PLUGIN_SYSTEM_PATH_1_0 = "/run/current-system/sw/lib/gstreamer-1.0";
}
