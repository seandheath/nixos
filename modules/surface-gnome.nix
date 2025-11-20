# surface-gnome.nix - GNOME configuration optimized for Surface touchscreen
{ config, lib, pkgs, ... }:

let
  username = "sheath";
in
{
  # Enable GNOME Desktop Environment
  services.xserver = {
    enable = true;
    displayManager.gdm = {
      enable = true;
      wayland = true;
    };
    desktopManager.gnome.enable = true;
  };

  # Exclude unwanted GNOME packages to save space
  environment.gnome.excludePackages = with pkgs; [
    gnome-tour
    gnome-music
    epiphany  # We'll install separately if needed
    geary
    totem
  ];

  # XDG portal for better app integration
  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-gnome
      pkgs.xdg-desktop-portal-gtk
    ];
    config.common.default = "*";
  };

  # Home Manager configuration for GNOME
  home-manager.users.${username} = { pkgs, lib, ... }: {

    # Enable dconf for GNOME settings
    dconf.settings = {
      # Enable touchscreen gestures
      "org/gnome/desktop/peripherals/touchscreen" = {
        click-method = "fingers";
      };

      # Enable on-screen keyboard
      "org/gnome/desktop/a11y/applications" = {
        screen-keyboard-enabled = true;
      };

      # Larger text for better touch targets
      "org/gnome/desktop/interface" = {
        text-scaling-factor = 1.25;
        cursor-size = 32;
        gtk-enable-primary-paste = false;
        enable-hot-corners = false;
        # Touch-optimized theme
        gtk-theme = "Adwaita";
        icon-theme = "Adwaita";
        font-name = "Cantarell 12";
        document-font-name = "Cantarell 12";
        monospace-font-name = "Source Code Pro 11";
      };

      # Auto-rotation support
      "org/gnome/settings-daemon/peripherals/touchscreen" = {
        orientation-lock = false;
      };

      # Power settings optimized for tablet
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-timeout = 1800;
        sleep-inactive-battery-timeout = 900;
        power-button-action = "suspend";
        idle-dim = true;
      };

      # Night light for eye comfort
      "org/gnome/settings-daemon/plugins/color" = {
        night-light-enabled = true;
        night-light-schedule-automatic = true;
        night-light-temperature = lib.hm.gvariant.mkUint32 3700;
      };

      # Touchpad/touch settings
      "org/gnome/desktop/peripherals/touchpad" = {
        tap-to-click = true;
        two-finger-scrolling-enabled = true;
        natural-scroll = true;
        disable-while-typing = true;
        click-method = "fingers";
      };

      # Window manager settings
      "org/gnome/desktop/wm/preferences" = {
        button-layout = "appmenu:minimize,maximize,close";
        resize-with-right-button = true;
        focus-mode = "click";
      };

      "org/gnome/mutter" = {
        edge-tiling = true;
        dynamic-workspaces = true;
        workspaces-only-on-primary = true;
        center-new-windows = true;
        # Enable experimental features for better touch support
        experimental-features = [ "scale-monitor-framebuffer" ];
      };

      # Shell settings
      "org/gnome/shell" = {
        favorite-apps = [
          "firefox.desktop"
          "org.gnome.Nautilus.desktop"
          "org.gnome.Terminal.desktop"
          "org.gnome.Calculator.desktop"
          "rnote.desktop"
          "org.gnome.Calendar.desktop"
          "org.gnome.Contacts.desktop"
        ];
        enabled-extensions = [
          "native-window-placement@gnome-shell-extensions.gcampax.github.com"
          "drive-menu@gnome-shell-extensions.gcampax.github.com"
        ];
      };

      # Keyboard shortcuts optimized for tablet mode
      "org/gnome/shell/keybindings" = {
        toggle-application-view = [ "<Super>space" ];
        toggle-overview = [ "<Super>s" ];
        show-screenshot-ui = [ "Print" ];
      };

      "org/gnome/desktop/wm/keybindings" = {
        close = [ "<Super>q" "<Alt>F4" ];
        toggle-fullscreen = [ "<Super>f" ];
        switch-applications = [ "<Super>Tab" ];
        switch-applications-backward = [ "<Shift><Super>Tab" ];
        move-to-workspace-up = [ "<Shift><Super>Page_Up" ];
        move-to-workspace-down = [ "<Shift><Super>Page_Down" ];
      };

      # File manager settings
      "org/gnome/nautilus/preferences" = {
        default-folder-viewer = "list-view";
        search-filter-time-type = "last_modified";
        show-hidden-files = false;
      };

      "org/gnome/nautilus/icon-view" = {
        default-zoom-level = "large";
      };

      "org/gnome/nautilus/list-view" = {
        default-zoom-level = "large";
        use-tree-view = false;
      };

      # Terminal settings with larger font
      "org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9" = {
        font = "Monospace 12";
        use-system-font = false;
        scrollback-unlimited = true;
      };

      # Input sources
      "org/gnome/desktop/input-sources" = {
        xkb-options = [ "caps:escape" ];
      };

      # Privacy settings
      "org/gnome/desktop/privacy" = {
        remove-old-temp-files = true;
        remove-old-trash-files = true;
        remember-recent-files = true;
      };

      # Location services for auto-timezone
      "org/gnome/system/location" = {
        enabled = true;
      };
    };

    # GNOME Extensions via home-manager
    home.packages = with pkgs.gnomeExtensions; [
      dash-to-dock         # Touch-friendly dock
      appindicator         # Tray icons
      gsconnect            # Phone integration
    ] ++ (with pkgs; [
      # Additional touch-friendly applications
      gnome-tweaks
      dconf-editor

      # Tablet-optimized apps
      apostrophe           # Distraction-free markdown editor
      fragments            # Torrent client with touch UI
      amberol             # Simple music player
      celluloid           # Video player
      gnome-clocks
      gnome-weather
      gnome-maps

      # Drawing and note-taking
      rnote               # Handwritten notes
      drawing             # Simple drawing
      xournalpp           # PDF annotation

      # Reading
      foliate             # E-book reader
      evince              # PDF viewer

      # Utilities
      gnome-sound-recorder
      snapshot            # Camera app

      # Browser
      firefox

      # Waydroid GUI
      waydroid
    ]);

    # GTK configuration
    gtk = {
      enable = true;
      theme = {
        name = "Adwaita";
        package = pkgs.gnome-themes-extra;
      };
      iconTheme = {
        name = "Adwaita";
        package = pkgs.adwaita-icon-theme;
      };
      gtk3.extraConfig = {
        gtk-application-prefer-dark-theme = false;
        gtk-decoration-layout = "menu:minimize,maximize,close";
      };
      gtk4.extraConfig = {
        gtk-application-prefer-dark-theme = false;
        gtk-decoration-layout = "menu:minimize,maximize,close";
      };
    };
  };

  # Environment variables for Wayland
  environment.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    GDK_BACKEND = "wayland,x11";
    CLUTTER_BACKEND = "wayland";
    SDL_VIDEODRIVER = "wayland";
    XDG_SESSION_TYPE = "wayland";
  };

  # System-wide packages for GNOME tablet support
  environment.systemPackages = with pkgs; [
    # GNOME apps and utilities
    gnome-console      # Modern terminal
    gnome-text-editor  # Simple text editor

    # Touch gesture tools
    touchegg           # Touch gesture recognizer

    # Screen rotation utilities
    iio-sensor-proxy   # Auto-rotation

    # Wayland utilities
    wl-clipboard
    wtype              # Wayland xdotool alternative
    ydotool            # Generic input automation

    # Screenshot tools (GNOME has built-in, but these are extras)
    grim
    slurp
    swappy             # Screenshot editor
  ];

  # Enable touchegg service for advanced gestures
  services.touchegg = {
    enable = true;
  };

  # PipeWire for audio
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  # Bluetooth support
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
        Experimental = true;
      };
    };
  };

  # Enable CUPS for printing
  services.printing.enable = true;

  # Enable GVfs for trash, mounting, etc.
  services.gvfs.enable = true;

  # Fonts for better rendering
  fonts.packages = with pkgs; [
    cantarell-fonts
    dejavu_fonts
    noto-fonts
    noto-fonts-color-emoji
    source-code-pro
    liberation_ttf
  ];

  # Automatic screen rotation
  hardware.sensor.iio.enable = true;

  # Enable location services
  services.geoclue2.enable = true;

  # GNOME Keyring for password management
  services.gnome.gnome-keyring.enable = true;
  programs.seahorse.enable = true;

  # Enable fingerprint reader if available
  # services.fprintd.enable = true;

  # Evolution data server (for GNOME Calendar, Contacts)
  services.gnome.evolution-data-server.enable = true;

  # GNOME Online Accounts
  services.gnome.gnome-online-accounts.enable = true;

  # Tracker for file indexing
  services.gnome.tracker-miners.enable = true;
  services.gnome.tracker.enable = true;

  # Sushi for file previews
  services.gnome.sushi.enable = true;

  # Waydroid - Android container for running Android apps
  virtualisation.waydroid.enable = true;

  # Kernel modules required for Waydroid
  boot.kernelModules = [ "binder_linux" "ashmem_linux" ];

  # Add binder devices for Waydroid
  boot.extraModprobeConfig = ''
    options binder_linux devices="binder,hwbinder,vndbinder"
  '';

  # LXC for Waydroid container support
  virtualisation.lxc.enable = true;

  # Networking for Waydroid
  networking.firewall.trustedInterfaces = [ "waydroid0" ];
}
