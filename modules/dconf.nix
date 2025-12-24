{ config, pkgs, lib,... }: {
  #dconf.settings = {
  programs.dconf.profiles = {
    user.databases = [{
      settings = with lib.gvariant; {
        "org/virt-manager/virt-manager/connections" = {
          autoconnect = ["qemu:///system"];
          uris = ["qemu:///system"];
        };
        "org/gnome/SessionManager" = {
          logout-prompt = false;
        };
        "org/gnome/shell" = {
          favorite-apps = [
            "org.gnome.Nautilus.desktop"
            "firefox.desktop"
            "org.keepassxc.KeePassXC.desktop"
          ];
        };
        "org/gnome/mutter" = {
          attach-modal-dialogs = false;
        };
        "org/gnome/desktop/background" = {
          picture-uri = "none";
          picture-uri-dark = "none";
          primary-color = "0x000000";
          color-shading-type = "solid";
        };
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
          enable-hot-corners = false;
          font-hinting = "slight";
          font-antialiasing = "grayscale";
          gtk-theme = "Adwaita-dark";
          text-scaling-factor = mkDouble 1.0;
        };
        "org/gnome/desktop/sound" = {
          allow-volume-above-100-percent = true;
        };
        "org/gnome/shell" = {
          disable-user-extensions = false;
          enabled-extensions = [
            "appindicatorsupport@rgcjonas.gmail.com"
            "gTile@vibou"
            "bluetooth-quick-connect@bjarosze.gmail.com"
	    "Vitals@CoreCoding.com"
	    "display-configuration-switcher@knokelmaat.gitlab.com"
          ];
        };
        "org/gnome/shell/extensions/gtile" = {
          grid-sizes = [ "4x2,3x2,1x3,1x2" ];
        };
        "org/gnome/desktop/peripherals/touchpad" = {
          tap-to-click = true;
          natural-scroll = true;
        };
        "org/gnome/desktop/a11y/applications" = {
          screen-keyboard-enabled = false;
        };
        "org/gnome/desktop/wm/keybindings" = {
          move-to-workspace-left = [ "<Primary><Shift><Alt>Left" ];
          move-to-workspace-right = [ "<Primary><Shift><Alt>Right" ];
          switch-applications = mkEmptyArray type.string;
          switch-applications-backward = mkEmptyArray type.string;
          switch-windows = [ "<Alt>Tab" ];
          switch-windows-backward = [ "<Shift><Alt>Tab" ];
        };
        "org/gnome/desktop/wm/preferences" = {
          button-layout = "appmenu:minimize,maximize,close";
        };
        "org/gnome/settings-daemon/plugins/power" = {
          sleep-inactive-ac-type = "nothing";
        };
        "org/gnome/settings-daemon/plugins/media-keys" = {
          custom-keybindings = [
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
          ];
          home = [ "<Super>e" ];
          area-screenshot-clip = [ "<Ctrl><Alt><Shift>s" ];
        };
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" =
          {
            binding = "<Alt>Return";
            command = "/etc/profiles/per-user/sheath/bin/kitty";
            name = "open-terminal";
          };
        "org/gnome/germinal/legacy".theme-variant = "dark";
      };
    }];
  };
}
