{ config, pkgs, lib, ... }: {
  # Automatic system updates with smart reboot notifications
  system.autoUpgrade = {
    enable = true;
    flake = "github:nixos/nixpkgs/nixos-unstable";  # Use flake format
    dates = "04:00";          # Run at 4 AM daily
    allowReboot = false;      # We'll handle reboot notifications manually
  };
  
  # Service to check for reboot requirements after update
  systemd.services.nixos-upgrade-notifier = {
    description = "Notify user about NixOS upgrade results";
    after = [ "nixos-upgrade.service" ];
    wants = [ "nixos-upgrade.service" ];
    
    serviceConfig = {
      Type = "oneshot";
      User = "sheath";
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
      ];
    };
    
    script = ''
      # Wait a moment for the upgrade to complete
      sleep 5
      
      # Check if the upgrade service succeeded
      if systemctl show -p Result --value nixos-upgrade.service | grep -q "success"; then
        # Upgrade succeeded, check if reboot is needed
        
        # Check if kernel was updated (main reason for reboot)
        CURRENT_KERNEL=$(readlink /run/current-system/kernel 2>/dev/null || echo "none")
        NEXT_KERNEL=$(readlink /nix/var/nix/profiles/system/kernel 2>/dev/null || echo "none")
        
        # Check if systemd was updated (another reason for reboot)
        CURRENT_SYSTEMD=$(readlink /run/current-system/systemd 2>/dev/null || echo "none")
        NEXT_SYSTEMD=$(readlink /nix/var/nix/profiles/system/systemd 2>/dev/null || echo "none")
        
        # Log the update
        echo "NixOS auto-update completed successfully at $(date)" | ${pkgs.systemd}/bin/systemd-cat -t nixos-upgrade-notifier
        
        # Check what changed and notify accordingly
        REBOOT_REQUIRED=false
        REASONS=""
        
        if [ "$CURRENT_KERNEL" != "$NEXT_KERNEL" ]; then
          REBOOT_REQUIRED=true
          REASONS="$REASONS kernel"
          echo "Kernel update detected: $CURRENT_KERNEL -> $NEXT_KERNEL" | ${pkgs.systemd}/bin/systemd-cat -t nixos-upgrade-notifier
        fi
        
        if [ "$CURRENT_SYSTEMD" != "$NEXT_SYSTEMD" ]; then
          REBOOT_REQUIRED=true
          REASONS="$REASONS systemd"
          echo "Systemd update detected: $CURRENT_SYSTEMD -> $NEXT_SYSTEMD" | ${pkgs.systemd}/bin/systemd-cat -t nixos-upgrade-notifier
        fi
        
        # Send appropriate notification
        if [ "$REBOOT_REQUIRED" = "true" ]; then
          # Critical notification that persists
          ${pkgs.libnotify}/bin/notify-send \
            -u critical \
            -t 0 \
            -i system-restart \
            "🔄 Reboot Required" \
            "NixOS updated successfully. Reboot required for:$REASONS

Click to dismiss, then reboot when convenient."
          
          # Also log to journal for remote monitoring
          echo "REBOOT REQUIRED: Updated components:$REASONS" | ${pkgs.systemd}/bin/systemd-cat -t nixos-upgrade-notifier -p warning
          
          # Create a flag file for other scripts to check
          touch /tmp/nixos-reboot-required
          echo "$(date): Reboot required for:$REASONS" > /tmp/nixos-reboot-required
          
        else
          # Normal notification for successful update without reboot
          ${pkgs.libnotify}/bin/notify-send \
            -u normal \
            -t 10000 \
            -i system-software-update \
            "✅ NixOS Updated" \
            "System updated successfully. No reboot required.

Services will restart automatically as needed."
          
          # Clean up reboot flag if it exists
          rm -f /tmp/nixos-reboot-required
        fi
        
      else
        # Upgrade failed
        echo "NixOS auto-update failed at $(date)" | ${pkgs.systemd}/bin/systemd-cat -t nixos-upgrade-notifier -p err
        
        # Send critical notification
        ${pkgs.libnotify}/bin/notify-send \
          -u critical \
          -t 0 \
          -i dialog-error \
          "❌ NixOS Update Failed" \
          "Automatic system update failed at $(date).

Check logs with: journalctl -u nixos-upgrade.service

You may need to run updates manually."
      fi
    '';
  };
  
  # Timer to trigger the notifier after upgrade attempts
  systemd.timers.nixos-upgrade-notifier = {
    wantedBy = [ "timers.target" ];
    after = [ "nixos-upgrade.timer" ];
    
    timerConfig = {
      OnCalendar = "04:05";  # Run 5 minutes after the upgrade
      Persistent = true;
      RandomizedDelaySec = "15min";  # Randomize by up to 15 minutes
    };
  };
  
  # Additional service to periodically remind about pending reboots
  systemd.services.reboot-reminder = {
    description = "Remind user about pending system reboot";
    
    serviceConfig = {
      Type = "oneshot";
      User = "sheath";  # Run as your user for notifications
    };
    
    script = ''
      # Only run if reboot flag exists and is older than 2 hours
      if [ -f /tmp/nixos-reboot-required ]; then
        if [ $(($(date +%s) - $(stat -c %Y /tmp/nixos-reboot-required))) -gt 7200 ]; then
          # Set up environment for notifications
          export DISPLAY=:0
          export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
          
          REASON=$(cat /tmp/nixos-reboot-required)
          ${pkgs.libnotify}/bin/notify-send \
            -u normal \
            -t 15000 \
            -i system-restart \
            "⏰ Reboot Still Pending" \
            "System update from earlier still requires reboot:

$REASON

Consider rebooting when convenient."
        fi
      fi
    '';
  };
  
  # Timer to run reboot reminders every 4 hours
  systemd.timers.reboot-reminder = {
    wantedBy = [ "timers.target" ];
    
    timerConfig = {
      OnCalendar = "*-*-* 08,12,16,20:00:00";  # 8 AM, 12 PM, 4 PM, 8 PM
      Persistent = true;
      RandomizedDelaySec = "15min";  # Randomize by up to 15 minutes
    };
  };
  
  # Ensure libnotify is available system-wide
  environment.systemPackages = with pkgs; [
    libnotify
  ];
  
  # Optional: Add a convenient command to check update status
  environment.shellAliases = {
    nixos-update-status = "journalctl -u nixos-upgrade.service -n 20";
    nixos-reboot-check = "if [ -f /tmp/nixos-reboot-required ]; then cat /tmp/nixos-reboot-required; else echo 'No reboot required'; fi";
  };
}