{ pkgs, ... }: {
  # Ptyxis is GNOME's GTK4/VTE terminal (replaced kitty). The home-manager module
  # is deliberately thin — it installs the package and can write custom palettes,
  # nothing else. Everything kitty kept in kitty.conf (font, login shell) is
  # GSettings here, so it lives in modules/dconf.nix with the rest of the GNOME
  # settings: org.gnome.Ptyxis plus the relocatable org.gnome.Ptyxis.Profile
  # schema under /org/gnome/Ptyxis/Profiles/<uuid>/.
  programs.ptyxis.enable = true;

  # The terminal font. programs.kitty used to pull this in via font.package;
  # nothing does now, so install it explicitly — NixOS' fontconfig scans
  # /etc/profiles/per-user/<name>/share/fonts, which is where useUserPackages
  # puts it. Must stay in sync with font-name in modules/dconf.nix: the family
  # name fontconfig exposes is "Inconsolata" (the package also ships the
  # ligature variant as a separate "Ligconsolata" family).
  home.packages = [ pkgs.inconsolata ];
}
