# sway.nix - Touch-optimized Sway for Surface Go
{ config, lib, pkgs, ... }:

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
      mako               # notifications
      light              # backlight control
      pamixer            # audio control
      playerctl          # media control
      
      # Touch-friendly launchers and tools
      nwg-drawer         # Full-screen app grid
      nwg-panel          # Touch-friendly panel
      nwg-dock           # MacOS-style dock
      nwg-menu           # Right-click menu
      wofi               # Backup launcher
      wvkbd              # On-screen keyboard (better for Sway)
      
      # Touch-friendly apps
      firefox
      nautilus           # Touch-friendly file manager
      gnome-calculator
      gnome-calendar
      evince            # PDF viewer
      eog               # Image viewer
      foliate           # eBook reader
      celluloid         # Video player
    ];
  };

  # XDG portal for better app integration
  xdg.portal = {
    enable = true;
    wlr.enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  home-manager.users.sheath = { pkgs, ... }: {
    
    # Sway configuration
    wayland.windowManager.sway = {
      enable = true;
      systemd.enable = true;
      
      config = rec {
        modifier = "Mod4";
        terminal = "foot";  # Lighter than alacritty for tablets
        
        # Larger gaps for touch
        gaps = {
          inner = 12;
          outer = 8;
          smartGaps = true;  # No gaps with single window
        };
        
        # Thicker borders for visibility
        window = {
          border = 4;
          titlebar = false;  # We'll use waybar instead
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
        
        # Touch-friendly keybindings (also work with keyboard)
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
          
          # Screenshot with touch-friendly selector
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
          
          # On-screen keyboard
          "type:keyboard" = {
            xkb_options = "caps:escape";
          };
        };
        
        # Startup applications
        startup = [
          # On-screen keyboard daemon
          { command = "wvkbd-mobintl --hidden -L 300"; }
          
          # Touch-friendly dock
          { command = "nwg-dock -d -i 64 -o eDP-1"; }
          
          # Notification daemon
          { command = "mako"; }
          
          # Gesture daemon
          { command = "fusuma -d"; }
          
          # Auto-rotate daemon (if supported)
          { command = "rot8"; always = true; }
        ];
        
        # Use waybar for status
        bars = [{
          command = "${pkgs.waybar}/bin/waybar";
          position = "top";
        }];
      };
      
      # Extra configuration for gestures and touch
      extraConfig = ''
        # Default to tabbed layout (better for touch)
        workspace_layout tabbed
        
        # Touch gestures (3-finger)
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
        
        # Edge swipes (if supported)
        bindgesture edge:bottom exec wvkbd-mobintl --toggle
        bindgesture edge:top exec nwg-panel
        
        # Floating windows configuration
        floating_minimum_size 400 x 300
        floating_maximum_size 1200 x 900
        
        # Smart window rules
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
        
        # Tablet mode switching
        set $tablet_mode "tablet: (t)abbed (s)tacking (h)orizontal (v)ertical (f)loat"
        mode $tablet_mode {
          bindsym t layout tabbed; mode "default"
          bindsym s layout stacking; mode "default"
          bindsym h splith; mode "default"
          bindsym v splitv; mode "default"
          bindsym f floating toggle; mode "default"
          bindsym Escape mode "default"
        }
        bindsym $mod+Tab mode $tablet_mode
        
        # Quick workspace grid (for touch)
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
        
        # Urgent window activation
        focus_on_window_activation smart
        
        # Border colors for better touch visibility
        default_border pixel 4
        default_floating_border pixel 4
        
        # Dim inactive windows slightly
        for_window [app_id=".*"] opacity 0.95
        for_window [app_id=".*" focused] opacity 1.0
      '';
    };
    
    # Waybar configuration
    programs.waybar = {
      enable = true;
      settings = {
        mainBar = {
          layer = "top";
          position = "top";
          height = 48;  # Large for touch
          
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
            tooltip = "Toggle on-screen keyboard";
          };
          
          "battery" = {
            format = "{icon} {capacity}%";
            format-icons = ["🔋" "🔋" "🔋" "🔋" "🔋"];
            format-charging = "⚡ {capacity}%";
          };
          
          "network" = {
            format-wifi = "📶 {signalStrength}%";
            format-disconnected = "❌";
            on-click = "foot -e nmtui";
          };
          
          "pulseaudio" = {
            format = "🔊 {volume}%";
            format-muted = "🔇";
            on-click = "pavucontrol";
            on-click-right = "pamixer -t";
          };
          
          "clock" = {
            format = "{:%H:%M}";
            format-alt = "{:%Y-%m-%d}";
            on-click = "gnome-calendar";
          };
          
          "custom/power" = {
            format = "⏻";
            on-click = "nwg-bar";  # Touch-friendly power menu
            tooltip = "Power menu";
          };
        };
      };
      
      style = ''
        * {
          font-family: "Noto Sans", "Font Awesome 6 Free";
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
    
    # Mako notification configuration
    services.mako = {
      enable = true;
      font = "Noto Sans 14";
      width = 400;
      height = 150;
      padding = "15";
      margin = "10";
      borderSize = 3;
      defaultTimeout = 5000;
      groupBy = "summary";
      anchor = "top-center";
    };
    
    # Foot terminal configuration (lightweight for tablets)
    programs.foot = {
      enable = true;
      settings = {
        main = {
          font = "monospace:size=12";
          pad = "10x10";
        };
        touch = {
          long-press-delay = 200;
        };
      };
    };
    
    # Firefox touch settings
    programs.firefox = {
      enable = true;
      package = pkgs.firefox;
      profiles.default = {
        settings = {
          "dom.w3c_touch_events.enabled" = 1;
          "browser.gesture.swipe.left" = "Browser:BackOrBackDuplicate";
          "browser.gesture.swipe.right" = "Browser:ForwardOrForwardDuplicate";
        };
      };
    };
  };
  
  # Environment variables
  environment.sessionVariables = {
    MOZ_ENABLE_WAYLAND = "1";
    MOZ_USE_XINPUT2 = "1";
  };
  
  # Additional packages for touch support
  environment.systemPackages = with pkgs; [
    fusuma              # Additional gesture support
    rot8                # Screen rotation daemon
    nwg-bar             # Touch-friendly power menu
    wl-clipboard        # Clipboard support
  ];
  
  # Enable light for backlight control
  programs.light.enable = true;
  
  # Sound for touch feedback
  sound.enable = true;
  hardware.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
}
