{ config, pkgs, lib, ... }:

let
  cynthionUdevRules = pkgs.writeTextFile {
    name = "cynthion-cable-udev-rules";
    destination = "/lib/udev/rules.d/60-cynthion-cable.rules";
    text = ''
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="615b", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="615c", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="0010", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="0001", TAG+="uaccess"
    '';
  };
in
{
  imports = [
    ./gnome.nix
    ./nix-ld.nix
    ./sops.nix
    ./dconf.nix
    ./audio.nix
    ./bluetooth.nix
    ./printing.nix
    ./packages-desktop.nix
    ./opencode.nix
    ./qwen-code.nix
    ./re-container.nix
    ./codex-container.nix
    ./mullvad.nix
  ];

  # Programs
  programs.firefox.enable = true;
  environment.systemPackages = [ pkgs.porkbun-domain-search-mcp ];

  # MCP launchers read these at process startup; no client config or Nix store path contains
  # credentials.
  sops.secrets.porkbun-api-key.owner = "sheath";
  sops.secrets.porkbun-secret-api-key.owner = "sheath";
  sops.secrets.ynab-api-token.owner = "sheath";

  # Grant the active session user access to Cynthion's bootloader, Apollo, and analyzer
  # USB identities without requiring a plugdev group.
  services.udev.packages = [ cynthionUdevRules ];

  # Avahi for network printer discovery (.local hostname resolution)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };
  services.flatpak.enable = true;

  # Wayland for Electron apps.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  # nix-direnv caches the dev shell so re-entry does not re-evaluate the flake.
  home-manager.users.sheath.programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Claude Code global config. Sourced from the repo CLAUDE.md so there is one copy.
  home-manager.users.sheath.home.file.".claude/CLAUDE.md".source = ../CLAUDE.md;
  home-manager.users.sheath.home.file.".claude/CLAUDE.md".force = true;

  # Claude Code permission rules, merged rather than declared: settings.json is NOT a
  # home.file because Claude Code writes to it itself, and a read-only store symlink makes
  # those writes fail. jq-merging keeps the file writable and our entries self-healing.
  # MCP rules match as mcp__<server> or mcp__<server>__<tool>; wildcards are not supported.
  home-manager.users.sheath.imports = [ ({ lib, pkgs, ... }: {
    home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # No `run` wrapper: every command here redirects, and the redirect would still fire
      # under --dry-run even though `run` swallowed the command.
      settings="$HOME/.claude/settings.json"
      mkdir -p "$(dirname "$settings")"
      [ -s "$settings" ] || echo '{}' > "$settings"
      ${pkgs.jq}/bin/jq '.permissions.allow = ((.permissions.allow // []) + [
        "mcp__ReVa",
        "mcp__porkbun__ping",
        "mcp__porkbun__check_domain",
        "mcp__porkbun__get_pricing"
      ] | unique)' \
        "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    '';
  }) ];

  # ReVa's MCP server is registered at USER scope in ~/.claude.json, not declared here: a
  # project-scope .mcp.json applies only to the directory claude is launched from, but ReVa
  # is one localhost endpoint acting on whatever Ghidra has open. Re-create with
  #   claude mcp add --scope user --transport http ReVa http://localhost:8080/mcp/message
}
