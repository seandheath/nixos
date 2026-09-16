# Installing a fleet machine

Boot a NixOS live ISO in UEFI mode, connect to the network, clone this repository,
and run `bash install.sh`. For the new hydrogen tower, use
`bash install.sh --host hydrogen`. A fresh installation does not require the old
system SSD. Select the existing `/data` filesystem to keep it; the system disk and
any separate `/home` disk are erased.

The installer checks defaults at startup and after edits. Choose a fleet profile
if it cannot identify one, resolve failed checks, supply the fleet secrets
passphrase, and press **r** when ready. It asks for a disk only when there is no
unambiguous default. A single blank internal disk is eligible; USB, read-only,
mounted and preserved-data disks are excluded. Review every disk on the final
**ERASE** screen. Nothing is partitioned before this confirmation.

Use arrows or **j/k** to move, **Enter** to edit or read check details, **/** to
filter a selection list, **Ctrl-U** to clear a text field, and **Esc** to cancel an
edit. Checks run in the background; results from an older edit are discarded.
**v** retries checks after an external change, such as connecting a disk.

## Settings

The normal choices follow the [NixOS graphical installer's modules](https://github.com/NixOS/nixpkgs/tree/d6524aaca2ff07876657ae2b323f24be4874944b/pkgs/by-name/ca/calamares-nixos-extensions/src):

- Computer name; language, regional format and timezone.
- Keyboard model, layout and variant, with a typing test. On a Linux console the
  test temporarily applies the chosen layout and restores it afterward. In a
  graphical terminal it tests the live session's layout, as the prompt states.
- Full name, login name, inherited or custom login password; inherited, matching,
  separate or locked root password; automatic graphical login.
- GNOME, Plasma 6, Xfce, Pantheon, Cinnamon, MATE, Enlightenment, LXQt, Budgie or
  no desktop; permission to install unfree software.
- Guided Btrfs storage, encryption, optional separate home disk, preserved data,
  swap size and advanced EFI/tmpfs-root sizes. Tmpfs root requires a profile with
  a complete persistence configuration.

An edited choice wins over saved installation choices, which win over profile
settings and detected defaults. Keeping a password inherited uses the profile's
existing secret; custom passwords require confirmation. Sulfur's inherited
root recovery policy requires a root password on a fresh install.

The fleet profile remains stable when the computer or login name changes.
Services, secrets, tailnet identity and rebuilds still use the selected profile.
The login replaces the profile's normal user; family profiles retain the separate
`sheath` administrator.

Turning off unfree software reports conflicting profile packages or drivers
before installation. It does not remove those packages. The pinned nixpkgs
currently cannot evaluate Enlightenment because its Python EFL dependency does
not support the default Python interpreter; automatic validation blocks that
choice before any erase. Other desktop choices are checked against the complete
system derivation too.

## Saved choices and retries

Validation uses a temporary checkout and writes neither generated configuration
nor secrets to the source checkout or target. Nix may populate its store/cache.
`bash install.sh --host hydrogen --dry-run` performs the same read-only checks;
missing passphrases or required selections are reported as failed checks.

After partitioning, choices and generated settings, hardware and disk modules
live in `/persist/nixos-install`. The installed checkout imports them from
`provisioning/<profile>/`. Nightly `fleet-rebuild` copies them into its fetched
checkout before rebuilding. Password hashes are root-only files under
`/persist/secrets`; neither passwords nor hashes are embedded in Nix source.

If installation fails while the target is mounted, restart the installer; it
loads the saved choices. After rebooting the live ISO, select the existing disk
layout and supply its encryption passphrase, then use **m** to mount it. Mounting
uses Disko's mount-only mode. Resume requires matching profile, partition
settings, filesystem UUIDs and physical disks; it cannot skip partitioning based
on a completion marker alone. Newly edited settings trigger a new installation
build while keeping the already formatted filesystems.

A fresh system install preserves only the filesystem selected for `/data`.
Service databases or files held on the old system disk still require restoration
from backup.

## Verification

Run from the repository root:

```sh
python3 -m unittest discover -s installer -p 'test_*.py'
python3 tests/evaluate-installer.py
nix build --no-link 'path:.#installer' 'path:.#installer.tests.unit'
```

The disposable VM tests can be run individually (replace the test filename):

```sh
nix build --no-link --impure --expr '
  let f = builtins.getFlake ("path:" + toString ./.);
  in import ./tests/installer-storage-vm.nix {
    inherit (f.inputs) nixpkgs disko; system = "x86_64-linux";
  }'
```

`installer-storage-vm.nix` checks the real guided layouts, swap, encryption,
separate home, resume identity and preserved multi-device data on virtual disks.
`disko-vm.nix` installs and boots a UEFI system and checks that one passphrase
opens both encrypted disks. Neither test touches physical disks or fleet hosts.
