# The fleet installer runs on the live ISO.  Keep the TUI in the Python standard
# library so building it never needs a compiler or a dependency download.
{ pkgs }:
let
  source = pkgs.lib.sourceFilesBySuffices ../installer [ ".py" ];
in
pkgs.writeShellApplication {
  name = "installer";
  runtimeInputs = with pkgs; [
    age
    mkpasswd
    util-linux # lsblk, blkid, mountpoint
    openssh # ssh-keygen
    git
    coreutils
    kbd
    ckbcomp
  ];
  text = ''
    export INSTALLER_XKB=${pkgs.xkeyboard_config}/share/X11/xkb/rules/base.xml
    export INSTALLER_LOCALES=${pkgs.glibcLocales}/share/i18n/SUPPORTED
    export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
    exec ${pkgs.python3}/bin/python ${source}/installer.py "$@"
  '';

  derivationArgs.passthru.tests.unit = pkgs.runCommand "installer-unit-tests" { nativeBuildInputs = [ pkgs.python3 pkgs.util-linux pkgs.age ]; } ''
    export PYTHONDONTWRITEBYTECODE=1
    export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
    mkdir source
    cp -r ${source} source/installer
    cp ${../install.sh} source/install.sh
    python -m unittest discover -s source/installer -p 'test_*.py'
    touch "$out"
  '';

  meta = {
    description = "TUI installer for this NixOS fleet";
    mainProgram = "installer";
  };
}
