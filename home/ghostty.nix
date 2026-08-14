{ pkgs, ... }: {
  # Ghostty owns ~/.config/ghostty/config, so unlike Ptyxis nothing terminal-related
  # has to live in modules/dconf.nix. See CHANGELOG 2026-08-14.
  programs.ghostty = {
    enable = true;
    settings = {
      font-family = "Inconsolata";
      # GNOME's 1.25 text-scaling-factor is applied by VTE but not by Ghostty, so the
      # point size is pre-scaled to render at the size Ptyxis did.
      font-size = 14;
      # Login shell, as Ptyxis' login-shell=true was: home.sessionPath lands in
      # ~/.profile, which .bashrc does not source. `direct:` skips the /bin/sh -c
      # wrapper so shell-integration detection still sees bash.
      command = "direct:bash --login";
    };
  };

  # NixOS' fontconfig scans /etc/profiles/per-user/<name>/share/fonts, which is where
  # useUserPackages puts this. Family name must match font-family above ("Inconsolata";
  # the package also ships the ligature variant as a separate "Ligconsolata" family).
  home.packages = [ pkgs.inconsolata ];
}
