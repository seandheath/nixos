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
          text-scaling-factor = mkDouble 1.25;
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
	    "caffeine@patapon.info"
          ];
        };
        "org/gnome/shell/extensions/gtile" = {
          grid-sizes = [ "2x3,3x2,4x4" ];
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
          sleep-inactive-battery-type = "nothing";
        };
        "org/gnome/settings-daemon/plugins/media-keys" = {
          custom-keybindings = [
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
          ];
          home = [ "<Super>e" ];
          # Area-select screenshot to clipboard, handled by gnome-shell itself. This
          # previously spawned flameshot, which needed three stacked workarounds on
          # GNOME Wayland (portal app-id, xcb overlay, HiDPI origin) and still dropped
          # the crop and saved the whole desktop. The shell's built-in needs no portal
          # round-trip, so none of that applies. Use `area-screenshot` instead of
          # `-clip` if you want it written to ~/Pictures rather than the clipboard.
          area-screenshot-clip = [ "<Ctrl><Alt><Shift>s" ];
        };
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" =
          {
            binding = "<Alt>Return";
            # --gtk-single-instance=true, matching the shipped desktop entry's
            # New Window action: a bare invocation forks a second process instead
            # of asking the running one for another window.
            command =
              "/etc/profiles/per-user/sheath/bin/ghostty --gtk-single-instance=true";
            name = "open-terminal";
          };
        "org/gnome/germinal/legacy".theme-variant = "dark";
      };
    }];
  };
}
