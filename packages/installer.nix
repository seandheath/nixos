# The fleet installer: choose a host and its disks, let disko partition, then
# nixos-install. Run it as root from a checkout on the live ISO.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "installer";
  version = "0.1.0";

  src = ../installer;
  cargoLock.lockFile = ../installer/Cargo.lock;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  # --suffix, so the live ISO's copies win and these are only a fallback. The minimal ISO
  # carries no age, which the age-key check needs, and no mkpasswd.
  #
  # Deliberately absent: nix, nixos-install, nixos-generate-config and nixos-enter. Those
  # must come from the running installer environment, not from this checkout's nixpkgs.
  postInstall = ''
    wrapProgram $out/bin/installer --suffix PATH : ${
      pkgs.lib.makeBinPath [
        pkgs.age
        pkgs.mkpasswd
        pkgs.util-linux # script, lsblk, blkid, mountpoint
        pkgs.openssh # ssh-keygen
        pkgs.git
        pkgs.coreutils
      ]
    }
  '';

  meta = {
    description = "TUI installer for this NixOS fleet";
    mainProgram = "installer";
  };
}
