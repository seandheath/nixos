{ config, lib, pkgs, ... }:

{
  # Enable systemd in initrd (required for LUKS unlock)
  boot.initrd.systemd.enable = true;

  # Impermanence configuration
  environment.persistence."/persist" = {
    hideMounts = true;

    # System directories to persist
    directories = [
      "/etc/nixos"                              # NixOS configuration
      "/etc/NetworkManager/system-connections"  # WiFi networks
      "/etc/ssh"                                # SSH host keys
      "/var/lib/bluetooth"                      # Bluetooth pairings
      "/var/lib/nixos"                          # NixOS state (user IDs, etc.)
      "/var/lib/systemd/coredump"               # Core dumps
      "/var/lib/systemd/timers"                 # Persistent timers
      "/var/lib/fwupd"                          # Firmware update state
      "/var/lib/power-profiles-daemon"          # Power profile state
      "/var/lib/flatpak"                        # Flatpak applications
      "/var/lib/mullvad-vpn"                    # Mullvad VPN state
      "/etc/mullvad-vpn"                        # Mullvad VPN account/settings

      # ASUS-specific
      "/etc/asusd"                              # asusctl configuration

      # Hardware/system state
      "/var/lib/systemd/backlight"              # Laptop backlight level
      "/var/lib/systemd/rfkill"                 # WiFi/BT kill switch state
      "/var/lib/NetworkManager"                 # NM internal state (leases, secret_key)
      "/var/db/sudo/lectured"                   # Suppress sudo lecture
      "/var/lib/cups"                           # CUPS printer config/jobs
      "/var/lib/libvirt"                        # VM disk images, configs
      "/var/lib/containers"                     # Podman images/layers
      { directory = "/var/lib/colord"; user = "colord"; group = "colord"; mode = "u=rwx,g=rx,o="; }
    ];

    # System files to persist
    files = [
      "/etc/machine-id"
      "/etc/adjtime"                            # Hardware clock adjustment
    ];
  };

  # Ensure /persist exists and has correct permissions
  systemd.tmpfiles.rules = [
    "d /persist 0755 root root -"
    "d /persist/etc 0755 root root -"
    "d /persist/var 0755 root root -"
    "d /persist/var/lib 0755 root root -"
    "d /persist/secrets 0700 root root -"
  ];

  # User home directory persistence
  environment.persistence."/persist".users.sheath = {
    directories = [
      ".config/wivrn"                              # WiVRn VR streaming settings
    ];
  };

  # Required for impermanence to work with users
  programs.fuse.userAllowOther = true;

  # Set passwords declaratively since /etc/shadow is wiped
  users.mutableUsers = false;

  # User password files (must exist in /persist/secrets/)
  users.users.sheath.hashedPasswordFile = "/persist/secrets/sheath-password";
  users.users.root.hashedPasswordFile = "/persist/secrets/root-password";

  # Btrfs maintenance
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/persist" ];
  };
}
