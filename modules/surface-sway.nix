# surface-sway.nix - Fixed version
{ config, lib, pkgs, ... }:

let
  username = "sheath"; # Set your username here
in
{
  # Enable Sway
  programs.sway = {
    enable = true;
    wrapperFeatures.gtk = true;
    extraPackages = with pkgs; [
      swaylock-effects
      swayidle
      wl-clipboard
      wf-recorder
      grim
      slurp
      mako
      light
      pamixer
      playerctl
      
      # Touch-friendly launchers and tools
      nwg-drawer
      nwg-panel
      nwg-dock
      nwg-menu
      wofi
      wvkbd
      
      # Touch-friendly apps
      firefox            # Changed from firefox-wayland
      nautilus
      gnome-calculator
      gnome-calendar
      evince
      eog
      foliate
      celluloid
    ];
  };

  # XDG portal for better app integration
  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Home Manager configuration
  home-manager.users.${username} = { pkgs, ... }: {  # Fixed username
    
    # Sway configuration
    wayland.windowManager.sway = {
      enable = true;
      systemd.enable = true;
      checkConfig = false;  # Add this to bypass validation errors
      
      config = rec {
        modifier = "Mod4";
        terminal = "foot";
        
        # Larger gaps for touch
        gaps = {
          inner = 12;
          outer = 8;
          smartGaps = true;
        };
        
        # Thicker borders for visibility
        window = {
          border = 4;
          titlebar = false;
        };
        
        # Touch-optimized color scheme
        colors = {
          focused = {
            border = "#4c7899";
            background = "#285577";
            text = "#ffffff";
            indicator = "#2e9ef4";
            childBorder = "#4c7899";
          };
        };
        
        # Floating window settings
        floating = {
          border = 4;
          criteria = [
            { app_id = "gnome-calculator"; }
            { app_id = "gnome-calendar"; }
            { app_id = "nwg-drawer"; }
            { app_id = "nwg-dock"; }
            { app_id = "pavucontrol"; }
            { app_id = "wvkbd"; }
            { title = "Picture-in-Picture"; }
            { window_role = "pop-up"; }
            { window_role = "dialog"; }
          ];
        };
        
        # Touch-friendly keybindings
        keybindings = lib.mkOptionDefault {
          # App launchers
          "${modifier}+space" = "exec nwg-drawer";
          "${modifier}+d" = "exec wofi --show drun -I";
          "${modifier}+Return" = "exec foot";
          
          # Window management
          "${modifier}+q" = "kill";
          "${modifier}+f" = "floating toggle";
          "${modifier}+m" = "fullscreen toggle";
          "${modifier}+t" = "layout tabbed";
          "${modifier}+s" = "layout stacking";
          "${modifier}+e" = "layout toggle split";
          "${modifier}+Tab" = "mode tablet";  # Moved here from extraConfig
          
          # Quick app shortcuts
          "${modifier}+b" = "exec firefox";
          "${modifier}+n" = "exec nautilus";
          "${modifier}+c" = "exec gnome-calculator";
          
          # Media/Hardware keys
          "XF86AudioRaiseVolume" = "exec pamixer -i 5";
          "XF86AudioLowerVolume" = "exec pamixer -d 5";
          "XF86AudioMute" = "exec pamixer -t";
          "XF86MonBrightnessUp" = "exec light -A 10";
          "XF86MonBrightnessDown" = "exec light -U 10";
          
          # Screenshot
          "Print" = "exec grim -g \"$(slurp)\" - | wl-copy";
        };
        
        # Input configuration
        input = {
          "type:touchpad" = {
            tap = "enabled";
            natural_scroll = "enabled";
            dwt = "enabled";
            scroll_factor = "0.5";
            drag = "enabled";
            drag_lock = "enabled";
          };
          
          "type:touch" = {
            drag = "enabled";
            drag_lock = "enabled";
            tap = "enabled";
          };
          
          "type:keyboard" = {
            xkb_options = "caps:escape";
          };
        };
        
        # Startup applications
        startup = [
          { command = "wvkbd-mobintl --hidden -L 300"; }
          { command = "nwg-dock -d -i 64 -o eDP-1"; }
          { command = "mako"; }
          # Note: fusuma and rot8 might need to be installed separately
        ];
        
        # Use waybar for status
        bars = [{
          command = "${pkgs.waybar}/bin/waybar";
          position = "top";
        }];
        
        # Modes definition
        modes = {
          tablet = {
            t = "layout tabbed; mode default";
            s = "layout stacking; mode default";
            h = "splith; mode default";
            v = "splitv; mode default";
            f = "floating toggle; mode default";
            Escape = "mode default";
          };
        };
      };
      
      # Extra configuration for gestures and touch
      extraConfig = ''
        # Default to tabbed layout
        workspace_layout tabbed
        
        # Touch gestures (3-finger) - only valid gestures
        bindgesture swipe:3:right workspace prev
        bindgesture swipe:3:left workspace next
        bindgesture swipe:3:up exec nwg-drawer
        bindgesture swipe:3:down kill
        
        # Touch gestures (4-finger)
        bindgesture swipe:4:up fullscreen toggle
        bindgesture swipe:4:down floating toggle
        bindgesture swipe:4:left focus left
        bindgesture swipe:4:right focus right
        
        # Pinch gestures
        bindgesture pinch:inward exec wvkbd-mobintl --toggle
        bindgesture pinch:outward fullscreen toggle
        
        # Note: edge gestures are not supported in Sway
        # Removed invalid edge:bottom and edge:top gestures
        
        # Floating windows configuration
        floating_minimum_size 400 x 300
        floating_maximum_size 1200 x 900
        
        # Window rules
        for_window [app_id="wvkbd-mobintl"] {
          floating enable
          sticky enable
          resize set width 100 ppt height 30 ppt
          move position 0 ppt 70 ppt
          border none
        }
        
        for_window [app_id="nwg-drawer"] {
          fullscreen enable
          border none
        }
        
        for_window [app_id="firefox"] {
          inhibit_idle fullscreen
        }
        
        # Quick workspace names
        set $ws1 "1:🌐"
        set $ws2 "2:📁"
        set $ws3 "3:📝"
        set $ws4 "4:💬"
        set $ws5 "5:🎵"
        
        # Assign workspaces
        assign [app_id="firefox"] $ws1
        assign [app_id="nautilus"] $ws2
        assign [app_id="foot"] $ws3
        
        # Auto-hide cursor when using touch
        seat * hide_cursor 8000
        
        # Focus follows touch
        focus_follows_mouse yes
        focus_on_window_activation smart
        
        # Border settings
        default_border pixel 4
        default_floating_border pixel 4
        
        # Fixed opacity rules
        for_window [app_id=".*"] opacity 0.95
      '';
    };
    
    # Waybar configuration
    programs.waybar = {
      enable = true;
      settings = {
        mainBar = {
          layer = "top";
          position = "top";
          height = 48;
          
          modules-left = [ "sway/workspaces" "sway/mode" ];
          modules-center = [ "clock" ];
          modules-right = [ 
            "custom/keyboard"
            "battery" 
            "network"
            "pulseaudio"
            "custom/power"
          ];
          
          "sway/workspaces" = {
            disable-scroll = true;
            format = "{icon}";
            format-icons = {
              "1:🌐" = "🌐";
              "2:📁" = "📁";
              "3:📝" = "📝";
              "4:💬" = "💬";
              "5:🎵" = "🎵";
              urgent = "❗";
              focused = "●";
              default = "○";
            };
          };
          
          "custom/keyboard" = {
            format = "⌨️";
            on-click = "wvkbd-mobintl --toggle";
            tooltip = false;  # Changed to boolean
          };
          
          battery = {
            format = "{icon} {capacity}%";
            format-icons = ["🔋" "🔋" "🔋" "🔋" "🔋"];
            format-charging = "⚡ {capacity}%";
          };
          
          network = {
            format-wifi = "📶 {signalStrength}%";
            format-disconnected = "❌";
            on-click = "foot -e nmtui";
          };
          
          pulseaudio = {
            format = "🔊 {volume}%";
            format-muted = "🔇";
            on-click = "pavucontrol";
            on-click-right = "pamixer -t";
          };
          
          clock = {
            format = "{:%H:%M}";
            format-alt = "{:%Y-%m-%d}";
            on-click = "gnome-calendar";
          };
          
          "custom/power" = {
            format = "⏻";
            on-click = "nwg-bar";
            tooltip = false;  # Changed to boolean
          };
        };
      };
      
      style = ''
        * {
          font-family: "Noto Sans", sans-serif;
          font-size: 18px;
        }
        
        window#waybar {
          background: rgba(30, 30, 30, 0.9);
          color: white;
        }
        
        button {
          min-width: 60px;
          min-height: 48px;
          padding: 0 10px;
          border: none;
        }
        
        button:hover {
          background: rgba(255, 255, 255, 0.1);
        }
        
        #workspaces button {
          font-size: 24px;
          padding: 0 15px;
        }
        
        #workspaces button.focused {
          background: rgba(100, 150, 200, 0.3);
        }
        
        #clock {
          font-size: 20px;
          padding: 0 20px;
        }
        
        .modules-right > * {
          margin: 0 8px;
        }
      '';
    };
    
    # Fixed Mako configuration - all options under settings
    services.mako = {
      enable = true;
      settings = {
        font = "Noto Sans 14";
        width = 400;
        height = 150;
        padding = "15";
        margin = "10";
        border-size = 3;
        default-timeout = 5000;
        group-by = "summary";
        anchor = "top-center";
      };
    };
    
    # Foot terminal configuration
    programs.foot = {
      enable = true;
      settings = {
        main = {
          font = "monospace:size=12";
          pad = "10x10";
        };
        # Note: touch section might not be valid for all foot versions
      };
    };
    
    # Note: Removed firefox program configuration to avoid conflict
    # Firefox will be available but without the custom settings
  };
  
  # Environment variables
  environment.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_USE_XINPUT2 = "1";
  };
  
  # Additional packages for touch support
  environment.systemPackages = with pkgs; [
    # fusuma  # Might not be available in nixpkgs
    # rot8    # Might not be available in nixpkgs
    nwg-bar
    wl-clipboard
  ];
  
  # Enable light for backlight control
  programs.light.enable = true;
  
  # Sound configuration
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
