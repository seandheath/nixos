{ config, lib, pkgs, ... }:

{
  # Enable systemd in initrd (required for rollback service)
  boot.initrd.systemd.enable = true;

  # Rollback service - wipes root on every boot
  boot.initrd.systemd.services.rollback = {
    description = "Rollback Btrfs root subvolume to pristine state";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-cryptsetup@cryptroot.service" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /mnt
      mount -o subvol=/ /dev/mapper/cryptroot /mnt

      # Delete all subvolumes under @root (handles nested subvolumes)
      btrfs subvolume list -o /mnt/@root | cut -f9 -d' ' | while read subvolume; do
        echo "Deleting nested subvolume: /$subvolume"
        btrfs subvolume delete "/mnt/$subvolume"
      done

      # Delete the root subvolume
      echo "Deleting @root subvolume"
      btrfs subvolume delete /mnt/@root

      # Restore from blank snapshot
      echo "Restoring @root from @root-blank snapshot"
      btrfs subvolume snapshot /mnt/@root-blank /mnt/@root

      umount /mnt
    '';
  };

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

      # ASUS-specific
      "/etc/asusd"                              # asusctl configuration
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

  # Required for impermanence to work with users
  programs.fuse.userAllowOther = true;

  # Set passwords declaratively since /etc/shadow is wiped
  users.mutableUsers = false;

  # User password files (must exist in /persist/secrets/)
  users.users.sheath.hashedPasswordFile = "/persist/secrets/sheath-password";
  users.users.root.hashedPasswordFile = "/persist/secrets/root-password";

  # SSH host keys from persist
  services.openssh.hostKeys = [
    { path = "/persist/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    { path = "/persist/etc/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 4096; }
  ];

  # Btrfs maintenance
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" ];
  };
}
