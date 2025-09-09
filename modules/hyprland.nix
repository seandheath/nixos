{ config, pkgs, lib, ... }: {
  # Enable Hyprland
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # Display Manager
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
    theme = "breeze";
  };

  # Essential Wayland and Hyprland packages
  environment.systemPackages = with pkgs; [
    # Wayland utilities
    wayland
    wayland-protocols
    wayland-utils
    wl-clipboard
    wlroots
    
    # Screenshot and screen recording
    grim
    slurp
    swappy
    wf-recorder
    
    # Notification daemon
    dunst
    libnotify
    
    # App launcher
    wofi
    rofi-wayland
    
    # Terminal
    alacritty
    kitty
    
    # Status bar
    waybar
    
    # Wallpaper
    hyprpaper
    swww
    
    # File manager
    dolphin
    pcmanfm
    
    # Polkit agent
    polkit_gnome
    
    # Network manager applet
    networkmanagerapplet
    
    # Audio control
    pavucontrol
    pamixer
    
    # Brightness control
    brightnessctl
    
    # System monitor
    btop
    
    # Font packages
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    font-awesome
    
    # Theme packages
    papirus-icon-theme
    breeze-gtk
    breeze-qt5
    
    # XDG utilities
    xdg-utils
    xdg-desktop-portal
    xdg-desktop-portal-hyprland
    xdg-desktop-portal-gtk
    
    # Authentication agent
    gnome.gnome-keyring
    seahorse
    
    # Media player
    mpv
    
    # Image viewer
    imv
    
    # PDF viewer
    zathura
    
    # Archive manager
    ark
  ];

  # Enable necessary services
  services.gnome.gnome-keyring.enable = true;
  security.pam.services.sddm.enableGnomeKeyring = true;
  
  # Polkit
  security.polkit.enable = true;
  
  # XDG portals
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Environment variables for Wayland
  environment.sessionVariables = {
    # Wayland-specific
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
    QT_QPA_PLATFORM = "wayland";
    QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
    SDL_VIDEODRIVER = "wayland";
    _JAVA_AWT_WM_NONREPARENTING = "1";
    CLUTTER_BACKEND = "wayland";
    GDK_BACKEND = "wayland";
    
    # XDG
    XDG_CURRENT_DESKTOP = "Hyprland";
    XDG_SESSION_TYPE = "wayland";
    XDG_SESSION_DESKTOP = "Hyprland";
  };

  # Enable sound
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    wireplumber.enable = true;
  };

  # Enable bluetooth
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  services.blueman.enable = true;

  # Default Hyprland configuration
  environment.etc."xdg/hypr/hyprland.conf".text = ''
    # Monitor configuration
    monitor=,preferred,auto,1

    # Execute at launch
    exec-once = waybar
    exec-once = dunst
    exec-once = hyprpaper
    exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
    exec-once = gnome-keyring-daemon --start --components=secrets
    exec-once = nm-applet --indicator

    # Input configuration
    input {
        kb_layout = us
        follow_mouse = 1
        touchpad {
            natural_scroll = true
            tap-to-click = true
        }
        sensitivity = 0
    }

    # General configuration
    general {
        gaps_in = 5
        gaps_out = 10
        border_size = 2
        col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
        col.inactive_border = rgba(595959aa)
        layout = dwindle
    }

    # Decoration
    decoration {
        rounding = 10
        blur {
            enabled = true
            size = 3
            passes = 1
        }
        drop_shadow = true
        shadow_range = 4
        shadow_render_power = 3
        col.shadow = rgba(1a1a1aee)
    }

    # Animations
    animations {
        enabled = true
        bezier = myBezier, 0.05, 0.9, 0.1, 1.05
        animation = windows, 1, 7, myBezier
        animation = windowsOut, 1, 7, default, popin 80%
        animation = border, 1, 10, default
        animation = borderangle, 1, 8, default
        animation = fade, 1, 7, default
        animation = workspaces, 1, 6, default
    }

    # Dwindle layout
    dwindle {
        pseudotile = true
        preserve_split = true
    }

    # Master layout
    master {
        new_is_master = true
    }

    # Window rules
    windowrule = float, ^(pavucontrol)$
    windowrule = float, ^(nm-connection-editor)$
    windowrule = float, ^(blueman-manager)$

    # Keybindings
    $mainMod = SUPER

    # Application shortcuts
    bind = $mainMod, Return, exec, alacritty
    bind = $mainMod, Q, killactive,
    bind = $mainMod, M, exit,
    bind = $mainMod, E, exec, dolphin
    bind = $mainMod, V, togglefloating,
    bind = $mainMod, Space, exec, wofi --show drun
    bind = $mainMod, P, pseudo,
    bind = $mainMod, J, togglesplit,
    bind = $mainMod, F, fullscreen,

    # Focus movement
    bind = $mainMod, left, movefocus, l
    bind = $mainMod, right, movefocus, r
    bind = $mainMod, up, movefocus, u
    bind = $mainMod, down, movefocus, d
    bind = $mainMod, h, movefocus, l
    bind = $mainMod, l, movefocus, r
    bind = $mainMod, k, movefocus, u
    bind = $mainMod, j, movefocus, d

    # Window movement
    bind = $mainMod SHIFT, left, movewindow, l
    bind = $mainMod SHIFT, right, movewindow, r
    bind = $mainMod SHIFT, up, movewindow, u
    bind = $mainMod SHIFT, down, movewindow, d
    bind = $mainMod SHIFT, h, movewindow, l
    bind = $mainMod SHIFT, l, movewindow, r
    bind = $mainMod SHIFT, k, movewindow, u
    bind = $mainMod SHIFT, j, movewindow, d

    # Workspace switching
    bind = $mainMod, 1, workspace, 1
    bind = $mainMod, 2, workspace, 2
    bind = $mainMod, 3, workspace, 3
    bind = $mainMod, 4, workspace, 4
    bind = $mainMod, 5, workspace, 5
    bind = $mainMod, 6, workspace, 6
    bind = $mainMod, 7, workspace, 7
    bind = $mainMod, 8, workspace, 8
    bind = $mainMod, 9, workspace, 9
    bind = $mainMod, 0, workspace, 10

    # Move to workspace
    bind = $mainMod SHIFT, 1, movetoworkspace, 1
    bind = $mainMod SHIFT, 2, movetoworkspace, 2
    bind = $mainMod SHIFT, 3, movetoworkspace, 3
    bind = $mainMod SHIFT, 4, movetoworkspace, 4
    bind = $mainMod SHIFT, 5, movetoworkspace, 5
    bind = $mainMod SHIFT, 6, movetoworkspace, 6
    bind = $mainMod SHIFT, 7, movetoworkspace, 7
    bind = $mainMod SHIFT, 8, movetoworkspace, 8
    bind = $mainMod SHIFT, 9, movetoworkspace, 9
    bind = $mainMod SHIFT, 0, movetoworkspace, 10

    # Scroll through workspaces
    bind = $mainMod, mouse_down, workspace, e+1
    bind = $mainMod, mouse_up, workspace, e-1

    # Move/resize with mouse
    bindm = $mainMod, mouse:272, movewindow
    bindm = $mainMod, mouse:273, resizewindow

    # Screenshots
    bind = , Print, exec, grim -g "$(slurp)"
    bind = SHIFT, Print, exec, grim
    bind = CTRL SHIFT, Print, exec, grim -g "$(slurp)" - | swappy -f -

    # Media controls
    bind = , XF86AudioRaiseVolume, exec, pamixer -i 5
    bind = , XF86AudioLowerVolume, exec, pamixer -d 5
    bind = , XF86AudioMute, exec, pamixer -t
    bind = , XF86AudioPlay, exec, playerctl play-pause
    bind = , XF86AudioNext, exec, playerctl next
    bind = , XF86AudioPrev, exec, playerctl previous

    # Brightness controls
    bind = , XF86MonBrightnessUp, exec, brightnessctl s +5%
    bind = , XF86MonBrightnessDown, exec, brightnessctl s 5%-
  '';

  # Hyprpaper configuration
  environment.etc."xdg/hypr/hyprpaper.conf".text = ''
    preload = ${pkgs.nixos-artwork.wallpapers.nineish-dark-gray.gnomeFilePath}
    wallpaper = ,${pkgs.nixos-artwork.wallpapers.nineish-dark-gray.gnomeFilePath}
  '';

  # Waybar configuration
  environment.etc."xdg/waybar/config".text = builtins.toJSON {
    layer = "top";
    position = "top";
    height = 30;
    
    modules-left = ["hyprland/workspaces" "hyprland/submap"];
    modules-center = ["hyprland/window"];
    modules-right = ["network" "cpu" "memory" "temperature" "pulseaudio" "clock" "tray"];
    
    "hyprland/workspaces" = {
      format = "{icon}";
      on-click = "activate";
      format-icons = {
        "1" = "1";
        "2" = "2";
        "3" = "3";
        "4" = "4";
        "5" = "5";
        "6" = "6";
        "7" = "7";
        "8" = "8";
        "9" = "9";
        "10" = "10";
      };
    };
    
    clock = {
      format = "{:%Y-%m-%d %H:%M}";
      tooltip-format = "{:%Y-%m-%d | %H:%M:%S}";
      interval = 1;
    };
    
    cpu = {
      format = "CPU: {usage}%";
      interval = 1;
    };
    
    memory = {
      format = "MEM: {}%";
      interval = 1;
    };
    
    network = {
      format-wifi = "WIFI: {essid}";
      format-ethernet = "ETH: {ipaddr}";
      format-disconnected = "Disconnected";
    };
    
    pulseaudio = {
      format = "VOL: {volume}%";
      format-muted = "MUTED";
      on-click = "pamixer -t";
      on-click-right = "pavucontrol";
    };
    
    temperature = {
      format = "TEMP: {temperatureC}°C";
    };
    
    tray = {
      spacing = 10;
    };
  };

  # Waybar style
  environment.etc."xdg/waybar/style.css".text = ''
    * {
      font-family: "Noto Sans", "Font Awesome 6 Free";
      font-size: 13px;
    }

    window#waybar {
      background-color: rgba(30, 30, 46, 0.9);
      border-bottom: 2px solid rgba(49, 50, 68, 0.9);
      color: #cdd6f4;
      transition-property: background-color;
      transition-duration: .5s;
    }

    #workspaces button {
      padding: 0 5px;
      background-color: transparent;
      color: #cdd6f4;
      border-radius: 6px;
    }

    #workspaces button.active {
      background-color: rgba(49, 50, 68, 0.9);
      color: #cba6f7;
    }

    #workspaces button:hover {
      background: rgba(49, 50, 68, 0.7);
      color: #cba6f7;
    }

    #clock, #cpu, #memory, #temperature, #network, #pulseaudio, #tray {
      padding: 0 10px;
    }

    #tray > .passive {
      -gtk-icon-effect: dim;
    }

    #tray > .needs-attention {
      -gtk-icon-effect: highlight;
    }
  '';
}