# The menu widgets shared by the couch pre-launcher and the per-machine launcher.
#
# Extracted from modules/minecraft-couch.nix, which had grown a complete keyboard+gamepad
# TUI inside a 975-line module. A second launcher wanting the same widgets is the point at
# which one copy stops being cheaper than two.
{ pkgs }:

pkgs.python3Packages.buildPythonPackage {
  pname = "minecraft-menu";
  version = "1.0";
  format = "other";

  src = ./.;

  # evdev is propagated so callers get it by depending on this alone.
  propagatedBuildInputs = [ pkgs.python3Packages.evdev ];

  # Pure widgets with no test suite; the couch regression test is the real check.
  doCheck = false;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/${pkgs.python3.sitePackages}
    cp -r minecraft_menu $out/${pkgs.python3.sitePackages}/
    runHook postInstall
  '';

  meta.description = "Keyboard and gamepad menu widgets for the Minecraft pre-launchers";
}
