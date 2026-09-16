# Exercise the real guided layouts and Python wipe/resume checks on disposable disks.
{ nixpkgs, disko, system }:
let
  pkgs = import nixpkgs { inherit system; };
  layout = encrypted: (nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [ disko.nixosModules.disko ../modules/disk-layout.nix {
      fleet.disk = {
        enable = true;
        system.device = "/dev/disk/by-id/installer-system";
        system.encrypt = encrypted;
        home.device = if encrypted then "/dev/disk/by-id/installer-home" else null;
        home.encrypt = encrypted;
        swapSize = "512M";
      };
    } ];
  }).config.system.build;
  plain = layout false;
  encrypted = layout true;
  resumeCheck = pkgs.writeText "check-resume.py" ''
    import json
    from dataclasses import asdict
    from pathlib import Path
    from installer import Board, Profile, command
    from storage import scan, storage_errors
    b = Board(Path('/tmp'), ['test'])
    b.profile = Profile('test', '/dev/disk/by-id/installer-system', system_encrypt=True,
                        home_device='/dev/disk/by-id/installer-home', home_encrypt=True, swap_size='512M')
    b.disks, b.filesystems = scan()
    state = Path('/mnt/persist/nixos-install')
    state.mkdir(parents=True)
    (state/'state').write_text('partition\n')
    choices = {'version': 1, 'profile': asdict(b.profile), 'settings': asdict(b.settings),
               'mount_uuids': {m: command(['findmnt', '-rn', '-M', '/mnt'+m, '-o', 'UUID'], 'UUID').strip()
                              for m in ('/boot', '/nix', '/home', '/persist')}}
    (state/'choices.json').write_text(json.dumps(choices))
    assert b.resume_matches(), 'matching mounted disks should resume'
    assert not storage_errors(b.disks, b.filesystems, b.profile.system_device, b.profile.home_device,
                              None, 'btrfs', resume=True)
    b.profile.esp_size = '2G'
    assert not b.resume_matches(), 'changed sizes must never resume'
    b.profile.esp_size = '1G'
    choices['mount_uuids']['/home'] = 'wrong-uuid'
    (state/'choices.json').write_text(json.dumps(choices))
    assert not b.resume_matches(), 'different mounted filesystems must never resume'
    preserved = next(f for f in b.filesystems if '/dev/vdd' in f.members)
    assert preserved.members == {'/dev/vdd', '/dev/vde'}
    for path in ('/dev/disk/by-id/installer-data1', '/dev/disk/by-id/installer-data2'):
        assert any('preserved' in e for e in storage_errors(b.disks, b.filesystems, path, None,
                                                            preserved.path, 'btrfs'))
  '';
in pkgs.testers.runNixOSTest {
  name = "installer-storage";
  nodes.machine = { pkgs, ... }: {
    virtualisation = {
      useEFIBoot = true;
      memorySize = 2048;
      emptyDiskImages = [ 16384 8192 4096 4096 ];
    };
    environment.systemPackages = with pkgs; [ python3 util-linux btrfs-progs cryptsetup ];
    environment.variables.PYTHONPATH = "${../installer}";
    services.udev.extraRules = ''
      KERNEL=="vdb", SYMLINK+="disk/by-id/installer-system"
      KERNEL=="vdc", SYMLINK+="disk/by-id/installer-home"
      KERNEL=="vdd", SYMLINK+="disk/by-id/installer-data1"
      KERNEL=="vde", SYMLINK+="disk/by-id/installer-data2"
    '';
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("test -d /sys/firmware/efi")
    machine.succeed("nixos-generate-config --show-hardware-config --no-filesystems > /tmp/detected-hardware.nix")
    machine.succeed("test -s /tmp/detected-hardware.nix")
    machine.succeed("udevadm settle; test -e /dev/disk/by-id/installer-system")
    # A real two-member preserved filesystem, outside Disko's device set.
    machine.succeed("mkfs.btrfs -f -d raid1 -m raid1 /dev/vdd /dev/vde")
    machine.succeed("mkdir /keep; mount /dev/vdd /keep; echo preserved > /keep/sentinel")
    machine.succeed("${plain.diskoScript} --yes-wipe-all-disks")
    machine.succeed("mountpoint /mnt/home; test -f /mnt/swap/swapfile")
    machine.succeed("test $(cat /keep/sentinel) = preserved")
    machine.succeed("swapoff -a; umount -R /mnt")
    machine.succeed("mkdir -p /tmp/nixos-install; echo -n test-passphrase > /tmp/nixos-install/luks.key")
    machine.succeed("${encrypted.diskoScript} --yes-wipe-all-disks")
    machine.succeed("test -b /dev/mapper/cryptroot; test -b /dev/mapper/crypthome")
    machine.succeed("python3 ${resumeCheck}")
    machine.succeed("test $(cat /keep/sentinel) = preserved")
  '';
}
