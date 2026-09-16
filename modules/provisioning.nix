# Marks hosts whose generated hardware and disk layout are local install artifacts.
{ config, lib, pkgs, ... }:

{
  options.fleet.profileName = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    description = "Stable flake identity, independent of the installed hostname.";
  };

  options.fleet.primaryUser = lib.mkOption {
    type = lib.types.strMatching "[a-z_][a-z0-9_-]*";
    default = if config.family.enable or false then config.fleet.profileName else "sheath";
    description = "Normal login configured by the installer.";
  };

  options.fleet.adminUser = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = if config.family.enable or false then "sheath" else config.fleet.primaryUser;
    description = "Fleet administrator; separate from the child's login on family hosts.";
  };

  options.fleet.desktop = lib.mkOption {
    type = lib.types.enum [ "inherit" "gnome" "plasma6" "xfce" "pantheon" "cinnamon" "mate" "enlightenment" "lxqt" "budgie" "none" ];
    default = "inherit";
    description = "Installed desktop; inherit preserves the existing fleet configuration.";
  };

  options.fleet.provisioning.enable = lib.mkEnableOption
    "machine-local hardware and disk provisioning state";

  options.fleet.hardware.isPlaceholder = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = "Whether this configuration still uses generated placeholder hardware.";
  };

  config = lib.mkMerge [
    {
      assertions = [{
        assertion = config.fleet.primaryUser != "root"
          && (!(config.family.enable or false) || config.fleet.primaryUser != "sheath");
        message = "The primary login must not replace root or the separate family administrator.";
      }];
    }
    (lib.mkIf (config.fleet.desktop != "inherit") {
      services.xserver.enable = lib.mkForce (config.fleet.desktop != "none");
      services.displayManager.gdm.enable = lib.mkForce (config.fleet.desktop == "gnome");
      services.displayManager.sddm.enable = lib.mkForce (config.fleet.desktop == "plasma6");
      services.xserver.displayManager.lightdm.enable = lib.mkForce
        (!(builtins.elem config.fleet.desktop [ "gnome" "plasma6" "none" ]));
      services.desktopManager.gnome.enable = lib.mkForce (config.fleet.desktop == "gnome");
      services.desktopManager.plasma6.enable = lib.mkForce (config.fleet.desktop == "plasma6");
      services.desktopManager.pantheon.enable = lib.mkForce (config.fleet.desktop == "pantheon");
      services.desktopManager.budgie.enable = lib.mkForce (config.fleet.desktop == "budgie");
      services.xserver.desktopManager.xfce.enable = lib.mkForce (config.fleet.desktop == "xfce");
      services.xserver.desktopManager.cinnamon.enable = lib.mkForce (config.fleet.desktop == "cinnamon");
      services.xserver.desktopManager.mate.enable = lib.mkForce (config.fleet.desktop == "mate");
      services.xserver.desktopManager.enlightenment.enable = lib.mkForce (config.fleet.desktop == "enlightenment");
      services.xserver.desktopManager.lxqt.enable = lib.mkForce (config.fleet.desktop == "lxqt");
    })
    (lib.mkIf (config.services.flatpak.enable && config.fleet.desktop != "inherit") {
      xdg.portal.enable = true;
      xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      xdg.portal.config.common.default = lib.mkDefault [ "gtk" ];
    })
    (lib.mkIf (config.fleet.desktop == "none") {
      services.flatpak.enable = lib.mkForce false;
      services.displayManager.autoLogin.enable = lib.mkForce false;
      systemd.user.services.rustdesk.enable = false;
      systemd.services.minecraft-couch.enable = false;
      systemd.services."getty@tty1".enable = lib.mkForce true;
      systemd.services."autovt@tty1".enable = lib.mkForce true;
    })
  ];
}
