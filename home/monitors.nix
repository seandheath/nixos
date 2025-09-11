{ config, pkgs, lib, ... }:

{
  home.packages = with pkgs; [
    xorg.xrandr
    edid-decode
  ];

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.file.".local/bin/dock-monitors" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash

      # Monitor configuration script for docking setup
      # Uses EDID information to identify monitors regardless of port changes

      # Detect monitors by their EDID information
      detect_monitors() {
          CENTER_MONITOR=""
          LEFT_MONITOR=""
          RIGHT_MONITOR=""
          
          # Find all connected outputs from xrandr
          for output in $(xrandr | grep " connected" | cut -d' ' -f1); do
              # Find corresponding DRM device
              for drm_path in /sys/class/drm/card*-$output/edid; do
                  if [ -s "$drm_path" ]; then
                      # Get monitor info from EDID
                      edid_info=$(cat "$drm_path" | edid-decode 2>/dev/null)
                      
                      # Check for Samsung QN90D (center 4K monitor)
                      if echo "$edid_info" | grep -q "Display Product Name: 'QN90D'"; then
                          CENTER_MONITOR=$output
                      # Check for HP Z27x monitors (side 1440p displays)
                      elif echo "$edid_info" | grep -q "Display Product Name: 'HP Z27x'"; then
                          # Identify which HP monitor by serial number
                          if echo "$edid_info" | grep -q "Display Product Serial Number: 'CNK6200PD8'"; then
                              LEFT_MONITOR=$output  # Assign this serial to left
                          elif echo "$edid_info" | grep -q "Display Product Serial Number: 'CNK71609WJ'"; then
                              RIGHT_MONITOR=$output  # Assign this serial to right
                          else
                              # Unknown HP Z27x, assign to any empty slot
                              if [ -z "$LEFT_MONITOR" ]; then
                                  LEFT_MONITOR=$output
                              elif [ -z "$RIGHT_MONITOR" ]; then
                                  RIGHT_MONITOR=$output
                              fi
                          fi
                      fi
                  fi
              done
          done
          
          # Fallback to physical dimensions if EDID detection fails
          if [ -z "$CENTER_MONITOR" ]; then
              CENTER_MONITOR=$(xrandr | grep " connected" | grep "950mm x 540mm" | cut -d' ' -f1)
          fi
          
          if [ -z "$LEFT_MONITOR" ] || [ -z "$RIGHT_MONITOR" ]; then
              # Get remaining 1440p monitors by size
              for mon in $(xrandr | grep " connected" | grep "600mm x 340mm" | cut -d' ' -f1); do
                  if [ "$mon" != "$LEFT_MONITOR" ] && [ "$mon" != "$RIGHT_MONITOR" ]; then
                      if [ -z "$LEFT_MONITOR" ]; then
                          LEFT_MONITOR=$mon
                      elif [ -z "$RIGHT_MONITOR" ]; then
                          RIGHT_MONITOR=$mon
                      fi
                  fi
              done
          fi
          
          echo "Detected monitors:"
          [ -n "$CENTER_MONITOR" ] && echo "  Center (Samsung QN90D): $CENTER_MONITOR"
          [ -n "$LEFT_MONITOR" ] && echo "  Left (HP Z27x S/N: PD8): $LEFT_MONITOR"
          [ -n "$RIGHT_MONITOR" ] && echo "  Right (HP Z27x S/N: 9WJ): $RIGHT_MONITOR"
      }

      # Check if all monitors are connected
      check_monitors() {
          local missing=0
          
          if [ -z "$LEFT_MONITOR" ]; then
              echo "Warning: Left monitor not detected"
              missing=1
          fi
          
          if [ -z "$CENTER_MONITOR" ]; then
              echo "Warning: Center monitor not detected"
              missing=1
          fi
          
          if [ -z "$RIGHT_MONITOR" ]; then
              echo "Warning: Right monitor not detected"
              missing=1
          fi
          
          return $missing
      }

      # Configure triple monitor setup
      configure_triple() {
          echo "Configuring triple monitor setup..."
          
          # Left monitor: 2560x1440, rotated left (portrait) -> becomes 1440x2560
          # Center monitor: 3840x2160 at 120Hz, primary
          # Right monitor: 2560x1440, rotated left (portrait) -> becomes 1440x2560
          
          # Calculate positions:
          # Left monitor at 0,0 (1440 wide when rotated)
          # Center monitor at 1440,0 (3840 wide)
          # Right monitor at 5280,0 (1440+3840)
          
          # Turn off all other outputs first to avoid conflicts
          for output in $(xrandr | grep " connected" | cut -d' ' -f1); do
              if [ "$output" != "$LEFT_MONITOR" ] && [ "$output" != "$CENTER_MONITOR" ] && [ "$output" != "$RIGHT_MONITOR" ]; then
                  xrandr --output "$output" --off
              fi
          done
          
          # Configure all three monitors in a single command
          xrandr \
              --output "$LEFT_MONITOR" --mode 2560x1440 --rotate left --pos 0x0 \
              --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary --pos 1440x0 \
              --output "$RIGHT_MONITOR" --mode 2560x1440 --rotate left --pos 5280x0
          
          echo "Triple monitor configuration applied!"
      }

      # Configure dual monitor setup (if one side monitor is missing)
      configure_dual() {
          echo "Configuring dual monitor setup..."
          
          if [ -n "$LEFT_MONITOR" ] && [ -n "$CENTER_MONITOR" ]; then
              xrandr \
                  --output "$LEFT_MONITOR" --mode 2560x1440 --rotate left --pos 0x0 \
                  --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary --pos 1440x190
          elif [ -n "$CENTER_MONITOR" ] && [ -n "$RIGHT_MONITOR" ]; then
              xrandr \
                  --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary --pos 0x0 \
                  --output "$RIGHT_MONITOR" --mode 2560x1440 --rotate left --pos 3840x0
          elif [ -n "$LEFT_MONITOR" ] && [ -n "$RIGHT_MONITOR" ]; then
              # Both side monitors but no center
              xrandr \
                  --output "$LEFT_MONITOR" --mode 2560x1440 --rotate left --pos 0x0 \
                  --output "$RIGHT_MONITOR" --mode 2560x1440 --rotate left --primary --pos 1440x0
          else
              echo "Unexpected dual monitor configuration"
          fi
          
          echo "Dual monitor configuration applied!"
      }

      # Configure single monitor (fallback)
      configure_single() {
          echo "Configuring single monitor setup..."
          
          if [ -n "$CENTER_MONITOR" ]; then
              xrandr --output "$CENTER_MONITOR" --mode 3840x2160 --rate 119.98 --primary
          elif [ -n "$LEFT_MONITOR" ]; then
              xrandr --output "$LEFT_MONITOR" --mode 2560x1440 --primary
          elif [ -n "$RIGHT_MONITOR" ]; then
              xrandr --output "$RIGHT_MONITOR" --mode 2560x1440 --primary
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
          
          # Detect monitors by EDID first
          detect_monitors
          
          # Count how many expected monitors we found
          monitor_count=0
          [ -n "$CENTER_MONITOR" ] && ((monitor_count++))
          [ -n "$LEFT_MONITOR" ] && ((monitor_count++))
          [ -n "$RIGHT_MONITOR" ] && ((monitor_count++))
          
          case $monitor_count in
              3)
                  configure_triple
                  ;;
              2)
                  configure_dual
                  ;;
              1)
                  configure_single
                  ;;
              0)
                  echo "Error: No expected monitors detected!"
                  echo "Falling back to auto-configuration..."
                  xrandr --auto
                  ;;
              *)
                  echo "Unexpected monitor count: $monitor_count"
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