# Declarative disk layout: one description drives both partitioning and fileSystems.
{ config, lib, ... }:

let
  cfg = config.fleet.disk;

  btrfsOpts = [ "compress=zstd" "noatime" "discard=async" ];

  homeOnSystemDisk = cfg.home.device == null;

  # settings lands verbatim in boot.initrd.luks.devices.<name>, so allowDiscards and
  # bypassWorkqueues here are the same knobs hardware/sulfur.nix set by hand.
  wrapLuks = name: encrypt: content:
    if !encrypt then content
    else {
      type = "luks";
      inherit name content;
      extraFormatArgs = [ "--type" "luks2" ];
      passwordFile = cfg.passwordFile;
      settings = {
        allowDiscards = true;
        bypassWorkqueues = true;
      };
    };

  systemSubvolumes =
    {
      "@nix" = { mountpoint = "/nix"; mountOptions = btrfsOpts; };
      # Always present: it holds the age key, the SSH host keys and the installer's own
      # resume state, none of which may live on a tmpfs root.
      "@persist" = { mountpoint = "/persist"; mountOptions = btrfsOpts; };
      "@log" = { mountpoint = "/var/log"; mountOptions = btrfsOpts; };
    }
    // lib.optionalAttrs (cfg.rootMode == "subvol") {
      "@root" = { mountpoint = "/"; mountOptions = btrfsOpts; };
    }
    // lib.optionalAttrs homeOnSystemDisk {
      "@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; };
    }
    // lib.optionalAttrs (cfg.swapSize != null) {
      "@swap" = {
        mountpoint = "/swap";
        mountOptions = [ "noatime" ];
        swap.swapfile.size = cfg.swapSize;
      };
    };

  # sops-install-secrets runs during initrd activation, so every path it or the account
  # hashes touch has to be mounted before stage 2. disko does not set this itself.
  bootCritical = [ "/nix" "/persist" "/var/log" "/home" ];
in
{
  options.fleet.disk = {
    enable = lib.mkEnableOption "declarative disko layout for this host";

    # Consumed only by `disko --mode destroy,format`; the booted system mounts by
    # partlabel, so this path never has to be right on an already-installed machine.
    system.device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-id/DISK-CONFIG-NOT-COMMITTED";
      description = "by-id path of the disk carrying the ESP and root.";
    };

    system.encrypt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wrap the root partition in LUKS2.";
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "Size of the EFI system partition.";
    };

    home.device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "by-id path of a separate /home disk. null keeps /home as a subvolume.";
    };

    home.encrypt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Wrap the separate /home disk in LUKS2.";
    };

    rootMode = lib.mkOption {
      type = lib.types.enum [ "subvol" "tmpfs" ];
      default = "subvol";
      description = "tmpfs gives an ephemeral root; subvol keeps / on @root.";
    };

    tmpfsSize = lib.mkOption {
      type = lib.types.str;
      default = "6G";
      description = "Size of the tmpfs root when rootMode is tmpfs.";
    };

    swapSize = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9]+[KMGTP]");
      default = null;
      description = "Btrfs swapfile size on @swap. Size it for RAM if hibernating.";
    };

    # Read only by `disko --mode format`, never by the booted system, and never written
    # into boot.initrd.luks. Every LUKS volume on the host is formatted from this one
    # file, so a single passphrase opens them all and systemd prompts once at boot.
    # The installer creates it; set null to be prompted per volume instead.
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/tmp/nixos-install/luks.key";
      description = "Format-time passphrase file. null prompts interactively.";
    };

    data.device = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "by-uuid path of an existing /data filesystem. Never formatted.";
    };

    data.fsType = lib.mkOption {
      type = lib.types.str;
      default = "btrfs";
      description = "Filesystem type of the preserved /data device.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.home.device == null || cfg.home.device != cfg.system.device;
        message = "fleet.disk: home.device and system.device are the same disk.";
      }
    ];

    disko.devices = {
      disk = {
        system = {
          type = "disk";
          device = cfg.system.device;
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = cfg.espSize;
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  extraArgs = [ "-n" "BOOT" "-F" "32" ];
                  # 0077, not the 0022 the old generator emitted: systemd-boot warns about
                  # a world-readable random seed otherwise.
                  mountOptions = [ "fmask=0077" "dmask=0077" ];
                };
              };
              root = {
                size = "100%";
                content = wrapLuks "cryptroot" cfg.system.encrypt {
                  type = "btrfs";
                  extraArgs = [ "-L" "nixos" ];
                  subvolumes = systemSubvolumes;
                };
              };
            };
          };
        };
      }
      // lib.optionalAttrs (!homeOnSystemDisk) {
        home = {
          type = "disk";
          device = cfg.home.device;
          content = {
            type = "gpt";
            partitions.home = {
              size = "100%";
              content = wrapLuks "crypthome" cfg.home.encrypt {
                type = "btrfs";
                extraArgs = [ "-L" "home" ];
                subvolumes."@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; };
              };
            };
          };
        };
      };
    }
    // lib.optionalAttrs (cfg.rootMode == "tmpfs") {
      nodev."/" = {
        fsType = "tmpfs";
        mountOptions = [ "defaults" "size=${cfg.tmpfsSize}" "mode=755" ];
      };
    };

    fileSystems = lib.genAttrs bootCritical (_: { neededForBoot = true; })
      // lib.optionalAttrs (cfg.data.device != null) {
        # Preserved, never in disko.devices: a multi-device btrfs mounts the whole array
        # off any member's shared UUID, and nothing here may reformat it.
        "/data" = {
          device = cfg.data.device;
          fsType = cfg.data.fsType;
          options = [ "noatime" "nofail" ]
            ++ lib.optional (cfg.data.fsType == "btrfs") "compress=zstd";
        };
      };
  };
}
