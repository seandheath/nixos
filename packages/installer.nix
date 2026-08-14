# The fleet installer: choose a host and its disks, let disko partition, then
# nixos-install. Run it as root from a checkout on the live ISO.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "installer";
  version = "0.1.0";

  src = ../installer;
  cargoLock.lockFile = ../installer/Cargo.lock;

  # Everything it drives is found on PATH at run time, on the ISO rather than here:
  # nix, disko, nixos-install, lsblk, age. Wrapping them in would pin the installer to
  # this checkout's nixpkgs instead of the one being installed.
  meta = {
    description = "TUI installer for this NixOS fleet";
    mainProgram = "installer";
  };
}
