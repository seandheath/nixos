{ config, pkgs, ... }: {
  home-manager.users.lo.dconf.settings = {
    "org/gnome/settings-daemon/plugins/power" = {
      power-button-action = "suspend-then-hibernate";
    };
  };
}
