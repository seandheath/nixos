{ config, pkgs, lib, ... }:

let
  hypr-dock-manager = pkgs.writeShellScriptBin "hypr-dock-manager" ''
    #!/usr/bin/env bash

    # Hyprland Dock Manager - Manages workspace layout when docking/undocking
    # This script should be run when dock state changes

    # Monitor descriptions from your config
    LEFT_MONITOR="desc:Hewlett Packard HP Z27x CNK71609WJ"
    CENTER_MONITOR="desc:Samsung Electric Company QN90D 0x01000E00"
    RIGHT_MONITOR="desc:Hewlett Packard HP Z27x CNK6200PD8"
    LAPTOP_MONITOR="desc:BOE 0x08EA"

    # Function to check if external monitors are connected
    check_dock_state() {
        local monitors=$(${pkgs.hyprland}/bin/hyprctl monitors -j)
        
        # Check if any of the external monitors are connected
        if echo "$monitors" | grep -q "Samsung Electric Company QN90D\|Hewlett Packard HP Z27x"; then
            echo "docked"
        else
            echo "undocked"
        fi
    }

    # Function to move all windows from a workspace to another
    move_workspace_windows() {
        local from_ws=$1
        local to_ws=$2
        
        # Get all windows in the source workspace
        local windows=$(${pkgs.hyprland}/bin/hyprctl clients -j | ${pkgs.jq}/bin/jq -r ".[] | select(.workspace.id == $from_ws) | .address")
        
        # Move each window to the target workspace
        for window in $windows; do
            ${pkgs.hyprland}/bin/hyprctl dispatch movetoworkspace "$to_ws,address:$window"
        done
    }

    # Function to setup docked configuration
    setup_docked() {
        echo "Setting up docked configuration..."
        
        # Assign workspaces to monitors
        ${pkgs.hyprland}/bin/hyprctl keyword workspace "1, monitor:$LEFT_MONITOR, default:true"
        ${pkgs.hyprland}/bin/hyprctl keyword workspace "2, monitor:$CENTER_MONITOR, default:true"
        ${pkgs.hyprland}/bin/hyprctl keyword workspace "3, monitor:$RIGHT_MONITOR, default:true"
        ${pkgs.hyprland}/bin/hyprctl keyword workspace "4, monitor:$LAPTOP_MONITOR, default:true"
        
        # Move existing workspaces to their designated monitors
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor "1 $LEFT_MONITOR"
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor "2 $CENTER_MONITOR"
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor "3 $RIGHT_MONITOR"
        ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor "4 $LAPTOP_MONITOR"
        
        # Set default workspaces for additional workspaces (5-10)
        for i in {5..10}; do
            ${pkgs.hyprland}/bin/hyprctl keyword workspace "$i, monitor:$CENTER_MONITOR"
        done
        
        echo "Docked configuration applied"
        ${pkgs.libnotify}/bin/notify-send "Dock Connected" "Workspace layout configured for docked mode"
    }

    # Function to setup undocked configuration
    setup_undocked() {
        echo "Setting up undocked configuration..."
        
        # First, collect all windows from external monitor workspaces
        # and move them to laptop workspaces
        
        # Move windows from workspace 2 and 3 to workspace 1 (consolidating)
        move_workspace_windows 2 1
        move_workspace_windows 3 1
        
        # Assign all workspaces to laptop monitor
        for i in {1..10}; do
            ${pkgs.hyprland}/bin/hyprctl keyword workspace "$i, monitor:$LAPTOP_MONITOR, default:true"
            ${pkgs.hyprland}/bin/hyprctl dispatch moveworkspacetomonitor "$i $LAPTOP_MONITOR"
        done
        
        echo "Undocked configuration applied"
        ${pkgs.libnotify}/bin/notify-send "Dock Disconnected" "All workspaces moved to laptop screen"
    }

    # Function to watch for monitor changes
    watch_mode() {
        echo "Watching for monitor changes..."
        local last_state=$(check_dock_state)
        echo "Initial state: $last_state"
        
        while true; do
            sleep 2
            local current_state=$(check_dock_state)
            
            if [ "$current_state" != "$last_state" ]; then
                echo "Dock state changed from $last_state to $current_state"
                
                case "$current_state" in
                    "docked")
                        setup_docked
                        ;;
                    "undocked")
                        setup_undocked
                        ;;
                esac
                
                last_state=$current_state
            fi
        done
    }

    # Main logic
    main() {
        # Parse command line arguments
        case "''${1:-}" in
            "watch")
                watch_mode
                ;;
            "docked")
                setup_docked
                ;;
            "undocked")
                setup_undocked
                ;;
            *)
                # Auto-detect and apply
                local dock_state=$(check_dock_state)
                
                case "$dock_state" in
                    "docked")
                        setup_docked
                        ;;
                    "undocked")
                        setup_undocked
                        ;;
                    *)
                        echo "Unknown dock state: $dock_state"
                        exit 1
                        ;;
                esac
                ;;
        esac
        
        # Reload waybar to update workspace display if not in watch mode
        if [ "''${1:-}" != "watch" ]; then
            ${pkgs.procps}/bin/pkill -SIGUSR2 waybar || true
        fi
    }

    # Run main function
    main "$@"
  '';

in
{
  home.packages = [ hypr-dock-manager pkgs.jq ];

  # Create systemd user service for automatic dock detection
  systemd.user.services.hypr-dock-watcher = {
    Unit = {
      Description = "Hyprland Dock Manager - Auto-detect dock state changes";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${hypr-dock-manager}/bin/hypr-dock-manager watch";
      Restart = "on-failure";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "hyprland-session.target" ];
    };
  };

  # Add keybindings to manually trigger dock/undock
  wayland.windowManager.hyprland.extraConfig = ''
    # Manual dock management keybindings
    bind = $mainMod ALT, D, exec, hypr-dock-manager docked
    bind = $mainMod ALT, U, exec, hypr-dock-manager undocked
    bind = $mainMod ALT, R, exec, hypr-dock-manager  # Auto-detect and apply
  '';
}