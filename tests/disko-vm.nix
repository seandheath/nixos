# Does a two-disk encrypted layout boot from ONE passphrase?
#
# This is the one question about fleet.disk that cannot be answered by reading Nix. The
# module's rendering is covered by evaluating fileSystems and boot.initrd.luks directly;
# what needs a running kernel is whether systemd's password cache carries the passphrase
# from the first LUKS volume to the second, or whether the operator is asked twice.
#
# makeDiskoTest takes a plain attrset, not a NixOS module, so the layout below cannot
# import modules/disk-layout.nix -- it mirrors what that module generates for
# system.encrypt = home.encrypt = true. Keep the two in step.
{ nixpkgs, disko, system }:

let
  pkgs = import nixpkgs { inherit system; };

  btrfsOpts = [ "compress=zstd" "noatime" "discard=async" ];

  # The installer writes one key file and formats every volume from it, so both headers
  # end up with the same passphrase. That is the mechanism under test.
  keyFile = "/tmp/luks.key";
  passphrase = "correct-horse-battery-staple";

  luks = name: content: {
    type = "luks";
    inherit name content;
    passwordFile = keyFile;
    settings = {
      allowDiscards = true;
      bypassWorkqueues = true;
    };
  };
in
disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "fleet-two-disk-luks";
  efi = true;
  testMode = "direct";

  disko-config = {
    disko.devices = {
      disk = {
        system = {
          type = "disk";
          device = "/dev/vdb";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "fmask=0077" "dmask=0077" ];
                };
              };
              root = {
                size = "100%";
                content = luks "cryptroot" {
                  type = "btrfs";
                  extraArgs = [ "-L" "nixos" ];
                  subvolumes = {
                    "@root" = { mountpoint = "/"; mountOptions = btrfsOpts; };
                    "@nix" = { mountpoint = "/nix"; mountOptions = btrfsOpts; };
                    "@persist" = { mountpoint = "/persist"; mountOptions = btrfsOpts; };
                    "@log" = { mountpoint = "/var/log"; mountOptions = btrfsOpts; };
                  };
                };
              };
            };
          };
        };
        home = {
          type = "disk";
          device = "/dev/vdc";
          content = {
            type = "gpt";
            partitions.home = {
              size = "100%";
              content = luks "crypthome" {
                type = "btrfs";
                extraArgs = [ "-L" "home" ];
                subvolumes."@home" = { mountpoint = "/home"; mountOptions = btrfsOpts; };
              };
            };
          };
        };
      };
    };
  };

  # The key file only has to exist while disko formats; the booted system never reads it.
  extraInstallerConfig = {
    boot.initrd.systemd.enable = true;
    systemd.tmpfiles.rules = [ "f ${keyFile} 0600 root root - ${passphrase}" ];
  };

  extraSystemConfig = {
    # Matches modules/boot-efi.nix. systemd stage 1 is what caches an entered passphrase
    # and retries it against later volumes; scripted stage 1 would ask twice.
    boot.initrd.systemd.enable = true;
    fileSystems."/nix".neededForBoot = true;
    fileSystems."/persist".neededForBoot = true;
    fileSystems."/var/log".neededForBoot = true;
    fileSystems."/home".neededForBoot = true;
  };

  # Answer the first prompt only. If systemd does not cache it, the second volume never
  # opens, /home never mounts and the test fails on the check below rather than hanging
  # silently.
  bootCommands = ''
    machine.wait_for_console_text("Please enter passphrase")
    machine.send_console("${passphrase}\n")
  '';

  extraTestScript = ''
    machine.succeed("test -b /dev/mapper/cryptroot")
    machine.succeed("test -b /dev/mapper/crypthome")
    # The real assertion: the second disk opened without a second prompt.
    machine.succeed("mountpoint /home")
    machine.succeed("findmnt --source /dev/mapper/crypthome /home")
    machine.succeed("findmnt --source /dev/mapper/cryptroot /nix")
  '';
}
