{ config, pkgs, lib, ... }: {
  imports = [
    ./gnome.nix
    ./sops.nix
    ./dconf.nix
    ./syncthing.nix
    ./auto-update.nix
    ./audio.nix
    ./bluetooth.nix
    ./printing.nix
    ./packages-desktop.nix
    ./opencode.nix
    ./qwen-code.nix
    ./re-container.nix
  ];

  # Programs
  programs.firefox.enable = true;

  # nix-ld for running dynamically linked executables (AppImages, etc.)
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      zstd
      stdenv.cc.cc.lib
      zlib
      glib
      libGL
      libx11
      libxcursor
      libxrandr
      libxi
      libxkbcommon
      wayland
      fontconfig
      freetype
      dbus
    ];
  };
  
  # Services
  # Cynthion udev rules (ships 54-cynthion.rules; TAG+="uaccess" grants the
  # active physical-session user device access — no plugdev group needed).
  services.udev.packages = [ pkgs.cynthion ];
  services.mullvad-vpn.enable = true;

  # Avahi for network printer discovery (.local hostname resolution)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  services.flatpak.enable = true;

  # Wayland support for Electron apps
  environment.sessionVariables.NIXOS_OZONE_WL = "1";
  #environment.sessionVariables.GST_PLUGIN_SYSTEM_PATH_1_0 = "/run/current-system/sw/lib/gstreamer-1.0";

  # direnv + nix-direnv: auto-load per-project `nix develop` shells on `cd`.
  # nix-direnv caches the dev shell so re-entry doesn't re-evaluate the flake.
  home-manager.users.sheath.programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Claude Code global config. Sourced from the repo CLAUDE.md so there is one copy.
  home-manager.users.sheath.home.file.".claude/CLAUDE.md".source = ../CLAUDE.md;
  home-manager.users.sheath.home.file.".claude/CLAUDE.md".force = true;

  # Claude Code permission rules, merged rather than declared.
  #
  # ~/.claude/settings.json is deliberately NOT a home.file: Claude Code writes to
  # it itself (/config toggles like `tui`, one-shot dialog acknowledgements), and a
  # read-only store symlink makes those writes fail. Instead this jq-merges the
  # rules we care about into whatever is already there on every rebuild, so the
  # file stays writable but our entries are self-healing.
  #
  # MCP rules match as mcp__<server> (whole server) or mcp__<server>__<tool> (one
  # tool). Wildcards such as mcp__ReVa__* are NOT supported — the bare server name
  # is what covers all of a server's tools.
  # Imported as a sub-module rather than assigned inline: lib.hm.dag only exists
  # inside home-manager's own module evaluation, not the NixOS one, and the rest
  # of this file already assigns into home-manager.users.sheath.* by attr path
  # (which cannot coexist with a direct `home-manager.users.sheath = ...`).
  home-manager.users.sheath.imports = [ ({ lib, pkgs, ... }: {
    home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # No `run` wrapper: every command here redirects, and the redirect would
      # still fire under `--dry-run` even though `run` swallowed the command.
      settings="$HOME/.claude/settings.json"
      mkdir -p "$(dirname "$settings")"
      [ -s "$settings" ] || echo '{}' > "$settings"
      ${pkgs.jq}/bin/jq '.permissions.allow = ((.permissions.allow // []) + ["mcp__ReVa"] | unique)' \
        "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    '';
  }) ];

  # ReVa's MCP server (packages/ghidra-reva.nix) is registered at *user* scope in
  # ~/.claude.json, deliberately not declared here.
  #
  # This started as a project-scope ~/projects/re/.mcp.json to keep the registration
  # in nix and off Claude Code's mutable state. That was wrong in practice: .mcp.json
  # only applies to the directory claude is launched from, but ReVa is a single
  # localhost endpoint that acts on whatever program Ghidra currently has open — it
  # is not per-project at all. Pinning it to one directory meant leaving the source
  # tree under ~/workspace to talk to it, which defeats the point of having source
  # and decompiler in the same session (e.g. porting ATF symbols into a BL31 dump).
  #
  # Re-create with:
  #   claude mcp add --scope user --transport http ReVa http://localhost:8080/mcp/message
  #
  # Not worth fighting to keep declarative: the endpoint is localhost-only and means
  # nothing without a Ghidra instance running on this same machine.
}
