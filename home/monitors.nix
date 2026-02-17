{ config, pkgs, lib, ... }:

let
  dock-monitors = import ../packages/dock-monitors.nix { inherit pkgs; };
in
{
  home.packages = [
    dock-monitors.pythonWithDbus
    dock-monitors.package
  ];

  # Automatically reapply monitor configuration after resume from sleep
  # This fixes GNOME losing rotation settings when resuming while docked
  systemd.user.services.dock-monitors-resume = {
    Unit = {
      Description = "Reapply monitor configuration after resume";
      After = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    };
    Service = {
      Type = "oneshot";
      # Wait for GNOME/Mutter to stabilize after resume before reconfiguring
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      ExecStart = "${dock-monitors.pythonWithDbus}/bin/python3 ${dock-monitors.script}";
      Environment = [
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
      ];
    };
    Install = {
      WantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
    };
  };
}
