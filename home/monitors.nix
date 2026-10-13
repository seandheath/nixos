{ pkgs, ... }:

{
  home.packages = [
    pkgs.dock-monitors.pythonWithDbus
    pkgs.dock-monitors.package
  ];
}
