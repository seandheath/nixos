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
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
          ];
          home = [ "<Super>e" ];
          # Free the built-in area screenshot; flameshot takes this chord below.
          area-screenshot-clip = mkEmptyArray type.string;
        };
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" =
          {
            binding = "<Alt>Return";
            command = "/etc/profiles/per-user/sheath/bin/kitty";
            name = "open-terminal";
          };
        # flameshot gui = interactive area select. Three env/spawn workarounds are
        # needed to make this usable on GNOME Wayland; each is load-bearing.
        #
        # Launched via systemd-run, NOT directly. gsd-media-keys runs in
        # session.slice/org.gnome.SettingsDaemon.MediaKeys.service and its children
        # inherit that cgroup, so xdg-desktop-portal attributes the Screenshot request
        # to that unit rather than to the empty (host) app-id. The only grant in the
        # permission store is for the empty app-id, so the portal fell back to a
        # permission dialog -- which mutter refuses to show, since flameshot has no
        # window and therefore no focus ("Only the focused app is allowed to show a
        # system access dialog"). Result was a silent "Unable to capture screen".
        # systemd-run places flameshot in its own app.slice unit, which the portal
        # maps to the empty app-id, matching the stored grant and skipping the dialog.
        #
        # Depends on undeclarable state: ~/.local/share/flatpak/db/screenshot. If that
        # is wiped, re-grant by running `flameshot gui` once from a focused terminal
        # and approving the prompt.
        #
        # QT_QPA_PLATFORM=xcb makes the selection overlay span all monitors. A Wayland
        # client cannot place one surface across several outputs, so the native overlay
        # only ever appeared on a single monitor. On the xcb platform it becomes an X11
        # window over rootless Xwayland's full 4000x3040 root, covering all three.
        # Capture is unaffected: flameshot still sources the image from the Screenshot
        # portal (verified -- an xcb-platform `flameshot full` returns the whole desktop
        # with real content, not the XWayland-only black grab an X11 grab would give).
        #
        # QT_FONT_DPI=96 fixes the overlay's origin. text-scaling-factor=1.25 sets
        # Xft.dpi=120, from which Qt6/xcb derives a 1.25 scale; the overlay was then
        # placed at x=-360 (1440 * 0.25) instead of x=0. Size was correct at 4000x3040,
        # so it hung off the left and left the rightmost 360px -- the right edge of the
        # laptop panel -- unselectable. Pinning 96 DPI restores +0+0 (measured via
        # xwininfo). Side effect: flameshot's own toolbar renders unscaled (1x).
        #
        # No --delay: the previous 200ms was credited to a chord-release race that
        # turned out not to be the bug (the real cause was the app-id/focus issue
        # above). Verified reliable without it.
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" =
          {
            binding = "<Ctrl><Alt><Shift>s";
            command =
              "/run/current-system/sw/bin/systemd-run --user --collect --quiet "
              + "-E QT_QPA_PLATFORM=xcb -E QT_FONT_DPI=96 "
              + "/run/current-system/sw/bin/flameshot gui";
            name = "flameshot-area";
          };
        "org/gnome/germinal/legacy".theme-variant = "dark";
      };
    }];
  };
}
