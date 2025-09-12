{ config, pkgs, lib, ... }:

let
  pythonWithDbus = pkgs.python3.withPackages (ps: with ps; [
    dbus-python
  ]);

  dock-monitors-script = pkgs.writeText "dock-monitors.py" ''
import dbus
import sys
from dbus import SessionBus, Interface

def get_display_config():
    """Get the current display configuration from GNOME"""
    bus = SessionBus()
    display_config = bus.get_object(
        'org.gnome.Mutter.DisplayConfig',
        '/org/gnome/Mutter/DisplayConfig'
    )
    return Interface(display_config, 'org.gnome.Mutter.DisplayConfig')

def find_monitors(resources):
    """Find our specific monitors by serial number"""
    serial, monitors, logical_monitors, props = resources
    
    samsung_monitor = None
    hp_left_monitor = None  # CNK71609WJ
    hp_right_monitor = None  # CNK6200PD8
    
    for monitor in monitors:
        connector, vendor, product, serial = monitor[0]
        modes = monitor[1]
        props = monitor[2]
        
        print(f"Found monitor: {vendor} {product} ({serial}) on {connector}")
        
        if vendor == 'SAM' and product == 'QN90D':
            samsung_monitor = (connector, monitor)
        elif vendor == 'HWP' and product == 'HP Z27x':
            if serial == 'CNK6200PD8':
                hp_right_monitor = (connector, monitor)  # PD8 is actually on the right
            elif serial == 'CNK71609WJ':
                hp_left_monitor = (connector, monitor)   # 9WJ is actually on the left
    
    return samsung_monitor, hp_left_monitor, hp_right_monitor

def find_best_mode(modes, width, height, refresh=None):
    """Find the best matching mode for given resolution"""
    best_mode = None
    best_refresh = 0
    
    for i, mode in enumerate(modes):
        mode_id, mode_width, mode_height, mode_refresh = mode[0], mode[1], mode[2], mode[3]
        mode_props = mode[6] if len(mode) > 6 else {}
        
        if mode_width == width and mode_height == height:
            # If specific refresh rate requested, try to match it
            if refresh and abs(mode_refresh - refresh) < 1:
                return i
            # Otherwise get the highest refresh rate
            if mode_refresh > best_refresh:
                best_mode = i
                best_refresh = mode_refresh
    
    return best_mode

def configure_triple_monitors():
    """Configure triple monitor setup with rotated side monitors"""
    
    display_config = get_display_config()
    
    # Get current state
    result = display_config.GetCurrentState()
    serial = result[0]
    monitors = result[1]
    logical_monitors = result[2]
    properties = result[3]
    resources = (serial, monitors, logical_monitors, properties)
    
    # Find our monitors
    samsung, hp_left, hp_right = find_monitors(resources)
    
    if not all([samsung, hp_left, hp_right]):
        print("Error: Could not find all three monitors!")
        print(f"  Samsung QN90D: {'Found' if samsung else 'Not found'}")
        print(f"  HP Z27x (9WJ - Left): {'Found' if hp_left else 'Not found'}")
        print(f"  HP Z27x (PD8 - Right): {'Found' if hp_right else 'Not found'}")
        return False
    
    # Build logical monitor configuration
    logical_monitors = []
    
    # Calculate vertical centering
    # Center monitor: 2160 pixels tall
    # Side monitors when rotated: 2560 pixels tall  
    # Difference: 2560 - 2160 = 400 pixels
    # To center: side monitors at y=0, center at y=200
    side_y = 0
    center_y = 200
    
    # Left monitor (HP Z27x 9WJ) - rotated right at position 0,0
    # When rotated, 2560x1440 becomes 1440x2560
    left_connector, left_monitor = hp_left
    left_modes = left_monitor[1]
    left_mode_idx = find_best_mode(left_modes, 2560, 1440, 60)
    if left_mode_idx is not None:
        mode = left_modes[left_mode_idx]
        mode_id = mode[0]
        logical_monitors.append((
            0,      # x position
            side_y, # y position
            1.0,    # scale
            1,      # transform (1 = rotate right/90°)
            False,  # primary
            [(left_connector, mode_id, {})],  # (connector, mode_id, properties)
        ))
        print(f"Configured left monitor: {left_connector} at 0,{side_y} (rotated) - mode: {mode_id}")
    
    # Center monitor (Samsung QN90D) - primary at position 1440,200 (vertically centered)
    center_connector, center_monitor = samsung
    center_modes = center_monitor[1]
    # Try for 120Hz first, fall back to 60Hz
    center_mode_idx = find_best_mode(center_modes, 3840, 2160, 120)
    if center_mode_idx is None:
        center_mode_idx = find_best_mode(center_modes, 3840, 2160, 60)
    
    if center_mode_idx is not None:
        mode = center_modes[center_mode_idx]
        mode_id = mode[0]
        logical_monitors.append((
            1440,     # x position
            center_y, # y position (pushed down to center)
            1.0,      # scale
            0,        # transform (0 = normal)
            True,     # primary
            [(center_connector, mode_id, {})],  # (connector, mode_id, properties)
        ))
        print(f"Configured center monitor: {center_connector} at 1440,{center_y} (primary, centered) - mode: {mode_id}")
    
    # Right monitor (HP Z27x PD8) - rotated right at position 5280,0
    right_connector, right_monitor = hp_right
    right_modes = right_monitor[1]
    right_mode_idx = find_best_mode(right_modes, 2560, 1440, 60)
    if right_mode_idx is not None:
        mode = right_modes[right_mode_idx]
        mode_id = mode[0]
        logical_monitors.append((
            5280,   # x position (1440 + 3840)
            side_y, # y position
            1.0,    # scale
            1,      # transform (1 = rotate right/90°)
            False,  # primary
            [(right_connector, mode_id, {})],  # (connector, mode_id, properties)
        ))
        print(f"Configured right monitor: {right_connector} at 5280,{side_y} (rotated) - mode: {mode_id}")
    
    # Apply configuration
    print("\nApplying monitor configuration...")
    try:
        # Method signature: (serial, method, logical_monitors, properties)
        # method: 1 = verify, 2 = temporary, 3 = persistent
        display_config.ApplyMonitorsConfig(
            serial,
            3,  # persistent
            logical_monitors,
            {}  # empty properties, let GNOME use defaults
        )
        print("Configuration applied successfully!")
        return True
    except Exception as e:
        print(f"Error applying configuration: {e}")
        return False

def main():
    """Main entry point"""
    permanent = '--permanent' in sys.argv
    
    print("GNOME Wayland Monitor Configuration")
    print("=" * 40)
    
    if configure_triple_monitors():
        print("\nMonitor configuration completed successfully!")
    else:
        print("\nFailed to configure monitors")
        sys.exit(1)

if __name__ == '__main__':
    main()
  '';
in
{
  home.packages = with pkgs; [
    pythonWithDbus
  ];

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.file.".local/bin/dock-monitors" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      exec ${pythonWithDbus}/bin/python3 ${dock-monitors-script} "$@"
    '';
  };
}