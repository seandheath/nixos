{ config, pkgs, lib, ... }:

let
  devBoardUdevRules = pkgs.writeTextFile {
    name = "dev-board-udev-rules";
    destination = "/lib/udev/rules.d/60-dev-boards.rules";
    text = ''
      # Cynthion: bootloader, Apollo, analyzer.
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="615b", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="615c", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="0010", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="0001", TAG+="uaccess"
      # TI XDS110 debug probe (LaunchPads): runtime and firmware-update modes.
      SUBSYSTEM=="usb", ATTR{idVendor}=="0451", ATTR{idProduct}=="bef3", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="0451", ATTR{idProduct}=="bef4", TAG+="uaccess"
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
  programs.nautilus-open-any-terminal = {
    enable = true;
    terminal = "alacritty";
  };
  sops.secrets.ynab-api-token.owner = config.fleet.adminUser;
  sops.secrets.remote-coding = {
    owner = config.fleet.adminUser;
    mode = "0400";
  };

  # Container launchers build through the host daemon; this lets them build aarch64-linux.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Grant the active session user access to dev-board USB identities without a plugdev
  # group. The container launchers' --allow-usb rides on these ACLs via keep-id.
  services.udev.packages = [ devBoardUdevRules ];

  # --allow-uart: podman --device snapshots the host inode at create time, so a replugged
  # port is a dead mount inside the container. Instead keep /dev/uart/<port> bound to
  # /dev/<port> for the device's lifetime; containers mount /dev/uart rslave so the binds
  # propagate in and out live. Whole-/dev was rejected: it would leak input/video nodes.
  services.udev.extraRules = ''
    SUBSYSTEM=="tty", KERNEL=="ttyACM*|ttyUSB*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="uart-bind@%k.service"
  '';
  # Exists from boot so containers can start before any port is plugged.
  systemd.tmpfiles.rules = [ "d /dev/uart 0755 root root -" ];
  systemd.services."uart-bind@" = {
    description = "Bind /dev/%i to /dev/uart/%i for containers";
    bindsTo = [ "dev-%i.device" ];
    after = [ "dev-%i.device" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.writeShellScript "uart-bind" ''
        set -e
        mkdir -p /dev/uart
        touch "/dev/uart/$1"
        exec ${pkgs.util-linux}/bin/mount --bind "/dev/$1" "/dev/uart/$1"
      ''} %i";
      # Lazy: a container may still hold the port open when it is unplugged.
      ExecStop = "${pkgs.util-linux}/bin/umount -l /dev/uart/%i";
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f /dev/uart/%i";
    };
  };

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
  home-manager.users.${config.fleet.adminUser} = {
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    # One instruction source for Claude and Codex, including their containers.
    home.file.".claude/CLAUDE.md".source = ../prompts/AGENTS.md;
    home.file.".claude/CLAUDE.md".force = true;
    home.file.".codex/AGENTS.md".source = ../prompts/AGENTS.md;

    # Claude Code permission rules, merged rather than declared: settings.json is NOT a
    # home.file because Claude Code writes to it itself, and a read-only store symlink makes
    # those writes fail. jq-merging keeps the file writable and our entries self-healing.
    # MCP rules match as mcp__<server> or mcp__<server>__<tool>; wildcards are not supported.
    imports = [ ({ lib, pkgs, ... }: {
      home.activation.claudeSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        # No `run` wrapper: every command here redirects, and the redirect would still fire
        # under --dry-run even though `run` swallowed the command.
        settings="$HOME/.claude/settings.json"
        mkdir -p "$(dirname "$settings")"
        [ -s "$settings" ] || echo '{}' > "$settings"
        ${pkgs.jq}/bin/jq '.permissions.allow = ((.permissions.allow // []) + ["mcp__ReVa"] | unique)' \
          "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
      '';
    }) ];

    # ReVa's MCP server is registered at USER scope in ~/.claude.json, not declared here: a
    # project-scope .mcp.json applies only to the directory claude is launched from, but ReVa
    # is one localhost endpoint acting on whatever Ghidra has open. Re-create with
    #   claude mcp add --scope user --transport http ReVa http://localhost:8080/mcp/message
  };
}
