{ config, pkgs, lib, ... }: {
  # Wayland support for Electron apps
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  
  # GNOME-specific system packages
  environment.systemPackages = with pkgs; [
    # GNOME Extensions
    gnomeExtensions.appindicator
    gnomeExtensions.gtile
    gnomeExtensions.bluetooth-quick-connect
    gnomeExtensions.vitals
    gnomeExtensions.display-configuration-switcher
    
    # GNOME Tools
    gnome-tweaks
    gnome-terminal
    
    # Desktop applications that integrate well with GNOME
    librsvg
    tectonic
    pandoc
    hugo
    mermaid-filter
    mullvad-vpn
    vmware-horizon-client
    element-desktop
    hexo-cli
    prusa-slicer
    openscad
    obsidian
    pavucontrol
    vlc
    jellyfin-media-player
    keepassxc
    appimage-run
    brasero
    blightmud
    signal-desktop
    libreoffice-fresh
    google-chrome
    lutris
    wine
    wine64
    wine-wayland
    winetricks
    vscodium
    discord
    xournalpp
  ];
  
  # Exclude unwanted GNOME packages
  environment.gnome.excludePackages = with pkgs; [
    epiphany
    gnome.gnome-music
    gnome.tali
    gnome.iagno
    gnome.hitori
    gnome.atomix
    gnome-tour
    evolution
  ];
  
  # Enable GNOME desktop environment
  services.xserver = {
    enable = true;
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };
  
  # Enable Mullvad VPN
  services.mullvad-vpn.enable = true;
  services.mullvad-vpn.package = pkgs.mullvad-vpn;
  
  # GNOME dconf settings
  programs.dconf.profiles = {
    user.databases = [{
      settings = with lib.gvariant; {
        "org/virt-manager/virt-manager/connections" = {
          autoconnect = ["qemu:///system"];
          uris = ["qemu:///system"];
        };
        "org/gnome/SessionManager" = {
          logout-prompt = false;
        };
        "org/gnome/shell" = {
          favorite-apps = [
            "org.gnome.Nautilus.desktop"
            "firefox.desktop"
            "org.keepassxc.KeePassXC.desktop"
          ];
          disable-user-extensions = false;
          enabled-extensions = [
            "appindicatorsupport@rgcjonas.gmail.com"
            "gTile@vibou"
            "bluetooth-quick-connect@bjarosze.gmail.com"
            "Vitals@CoreCoding.com"
            "display-configuration-switcher@knokelmaat.gitlab.com"
          ];
        };
        "org/gnome/shell/extensions/gtile" = {
          grid-sizes = [ "4x2,3x2,1x3,1x2" ];
        };
        "org/gnome/mutter" = {
          attach-modal-dialogs = false;
        };
        "org/gnome/desktop/background" = {
          picture-uri = "none";
          picture-uri-dark = "none";
          primary-color = "0x000000";
          color-shading-type = "solid";
        };
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          enable-hot-corners = false;
          font-hinting = "slight";
          font-antialiasing = "grayscale";
          gtk-theme = "Adwaita-dark";
        };
        "org/gnome/desktop/sound" = {
          allow-volume-above-100-percent = true;
        };
        "org/gnome/desktop/peripherals/touchpad" = {
          tap-to-click = true;
          natural-scroll = true;
        };
        "org/gnome/desktop/wm/keybindings" = {
          move-to-workspace-left = [ "<Primary><Shift><Alt>Left" ];
          move-to-workspace-right = [ "<Primary><Shift><Alt>Right" ];
          switch-applications = mkEmptyArray type.string;
          switch-applications-backward = mkEmptyArray type.string;
          switch-windows = [ "<Alt>Tab" ];
          switch-windows-backward = [ "<Shift><Alt>Tab" ];
        };
        "org/gnome/desktop/wm/preferences" = {
          button-layout = "appmenu:minimize,maximize,close";
        };
        "org/gnome/settings-daemon/plugins/media-keys" = {
          custom-keybindings = [
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
          ];
          home = [ "<Super>e" ];
          area-screenshot-clip = [ "<Ctrl><Alt><Shift>s" ];
        };
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
          binding = "<Alt>Return";
          command = "/run/current-system/sw/bin/alacritty";
          name = "open-terminal";
        };
        "org/gnome/terminal/legacy".theme-variant = "dark";
      };
    }];
  };
}
