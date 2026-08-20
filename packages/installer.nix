# The fleet installer runs on the live ISO.  Keep the TUI in the Python standard
# library so building it never needs a compiler or a dependency download.
{ pkgs }:

pkgs.writeShellApplication {
  name = "installer";
  runtimeInputs = with pkgs; [
    age
    mkpasswd
    util-linux # script, lsblk, blkid, mountpoint
    openssh # ssh-keygen
    git
    coreutils
  ];
  text = ''
    exec ${pkgs.python3}/bin/python ${../installer/installer.py} "$@"
  '';

  meta = {
    description = "TUI installer for this NixOS fleet";
    mainProgram = "installer";
  };
}
