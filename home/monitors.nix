{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    xorg.xrandr
  ];

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.file.".local/bin/dock-monitors" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash

      # Monitor configuration script for docking setup
      # Adjust the variables below to match your preferred layout

      # Monitor identifiers (from xrandr)
      LEFT_MONITOR="DP-11"
      CENTER_MONITOR="DP-13"
      RIGHT_MONITOR="DP-9"

      # Check if all monitors are connected
      check_monitors() {
          local missing=0
          
          if ! xrandr | grep -q "$LEFT_MONITOR connected"; then
              echo "Warning: $LEFT_MONITOR not connected"
              missing=1
          fi
          
          if ! xrandr | grep -q "$CENTER_MONITOR connected"; then
              echo "Warning: $CENTER_MONITOR not connected"
              missing=1
          fi
          
          if ! xrandr | grep -q "$RIGHT_MONITOR connected"; then
              echo "Warning: $RIGHT_MONITOR not connected"
              missing=1
          fi
          
          return $missing
      }

      # Configure triple monitor setup
      configure_triple() {
          echo "Configuring triple monitor setup..."
          
          # Left monitor: 2560x1440, rotated left (portrait)
          # Center monitor: 3840x2160 at 120Hz, primary
          # Right monitor: 2560x1440, rotated left (portrait)
          
          xrandr \
              --output "$LEFT_MONITOR" --mode 2560x1440 --rotate left --pos 0x0 \
              --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary --pos 1440x190 \
              --output "$RIGHT_MONITOR" --mode 2560x1440 --rotate left --pos 5280x0
          
          echo "Triple monitor configuration applied!"
      }

      # Configure dual monitor setup (if one side monitor is missing)
      configure_dual() {
          echo "Configuring dual monitor setup..."
          
          if xrandr | grep -q "$LEFT_MONITOR connected" && xrandr | grep -q "$CENTER_MONITOR connected"; then
              xrandr \
                  --output "$LEFT_MONITOR" --mode 2560x1440 --rotate left --pos 0x0 \
                  --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary --pos 1440x190
          elif xrandr | grep -q "$CENTER_MONITOR connected" && xrandr | grep -q "$RIGHT_MONITOR connected"; then
              xrandr \
                  --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary --pos 0x0 \
                  --output "$RIGHT_MONITOR" --mode 2560x1440 --rotate left --pos 3840x0
          else
              echo "Unexpected dual monitor configuration"
          fi
          
          echo "Dual monitor configuration applied!"
      }

      # Configure single monitor (fallback)
      configure_single() {
          echo "Configuring single monitor setup..."
          
          if xrandr | grep -q "$CENTER_MONITOR connected"; then
              xrandr --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary
          else
              # Just set the first connected monitor as primary
              local first_monitor=$(xrandr | grep " connected" | head -1 | cut -d' ' -f1)
              xrandr --output "$first_monitor" --auto --primary
          fi
          
          echo "Single monitor configuration applied!"
      }

      # Main logic
      main() {
          echo "Detecting monitor configuration..."
          
          # Count connected monitors
          monitor_count=$(xrandr | grep -c " connected")
          
          case $monitor_count in
              3)
                  if check_monitors; then
                      configure_triple
                  else
                      echo "Not all expected monitors found, falling back..."
                      configure_dual
                  fi
                  ;;
              2)
                  configure_dual
                  ;;
              1)
                  configure_single
                  ;;
              0)
                  echo "Error: No monitors detected!"
                  exit 1
                  ;;
              *)
                  echo "Detected $monitor_count monitors, attempting auto-configuration..."
                  xrandr --auto
                  ;;
          esac
          
          # Optional: restart compositor or panel if needed
          # killall polybar 2>/dev/null && polybar &
          # nitrogen --restore &  # Restore wallpaper if using nitrogen
      }

      # Run main function
      main
    '';
  };
}