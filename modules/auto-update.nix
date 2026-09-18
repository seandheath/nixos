# NixOS owns the timer, build, activation and reboot policy. Hydrogen publishes the lock.
{ config, pkgs, lib, ... }:
let
  remote = "git@github.com:seandheath/nixos";
  publicRemote = "https://github.com/seandheath/nixos.git";
  host = config.fleet.profileName;

  # Both callers own disposable checkouts; never run this against a user's working tree.
  checkout = url: ''
    if [ ! -d "$repo/.git" ]; then
      rm -rf -- "$repo"
      git clone --depth 1 --branch main ${lib.escapeShellArg url} "$repo"
    fi
    git -C "$repo" fetch --depth 1 ${lib.escapeShellArg url} main
    git -C "$repo" reset --hard FETCH_HEAD
    git -C "$repo" clean -ffdx
  '';

  prepare = pkgs.writeShellApplication {
    name = "fleet-prepare";
    runtimeInputs = [ pkgs.git pkgs.coreutils config.nix.package ];
    text = ''
      repo="$1"
      provision="''${2:-}"
      ${checkout publicRemote}
      if [ -n "$provision" ]; then
        target="$repo/provisioning/${host}"
        rm -rf -- "$target"
        mkdir -p "$target"
        install -m 0600 "$provision/default.nix" "$provision/disk.nix" "$provision/hardware.nix" "$target/"
        if [ -f "$provision/settings.nix" ]; then
          install -m 0600 "$provision/settings.nix" "$target/"
        fi
      fi
      placeholder="$(nix eval --json --no-update-lock-file \
        "path:$repo#nixosConfigurations.${host}.config.fleet.hardware.isPlaceholder")"
      if [ "$placeholder" != false ]; then
        echo "refusing rebuild: ${host} still has placeholder hardware" >&2
        exit 1
      fi
    '';
  };
  provisionArg = lib.optionalString config.fleet.provisioning.enable " /persist/nixos-install";

  rebuild = pkgs.writeShellApplication {
    name = "fleet-rebuild";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      action="''${1:-switch}"
      case "$action" in switch|boot|build) ;; *) echo "usage: fleet-rebuild [switch|boot|build]" >&2; exit 2;; esac
      work="$(mktemp -d)"
      trap 'rm -rf -- "$work"' EXIT
      ${prepare}/bin/fleet-prepare "$work/checkout"${provisionArg}
      ${config.system.build.nixos-rebuild}/bin/nixos-rebuild "$action" \
        --flake "path:$work/checkout#${host}" --no-update-lock-file -L
    '';
  };

  publish = pkgs.writeShellApplication {
    name = "nixos-lock-update";
    runtimeInputs = [ pkgs.git pkgs.coreutils config.nix.package pkgs.openssh ];
    text = ''
      repo="$STATE_DIRECTORY/checkout"
      ${checkout remote}
      # Move integration modules with nixpkgs. Each host builds before activating.
      nix flake update --flake "$repo"
      git -C "$repo" diff --quiet -- flake.lock && exit 0
      git -C "$repo" -c user.name=hydrogen -c user.email=seanheath@gmail.com \
        commit -m "chore(flake): nightly input update" -- flake.lock
      git -C "$repo" push ${lib.escapeShellArg remote} HEAD:main
    '';
  };
in
{
  options.fleet.lockUpdate.enable = lib.mkEnableOption "nightly publication of the fleet lockfile (one host only)";

  config = lib.mkMerge [
    {
      system.autoUpgrade = {
        enable = true;
        flake = "path:/var/lib/nixos-upgrade/checkout#${host}";
        upgrade = false;
        flags = [ "-L" "--no-update-lock-file" ];
        dates = lib.mkDefault "04:00";
        randomizedDelaySec = lib.mkDefault "45min";
      };
      systemd.services.nixos-upgrade.serviceConfig = {
        StateDirectory = "nixos-upgrade";
        ExecStartPre = [ "${prepare}/bin/fleet-prepare /var/lib/nixos-upgrade/checkout${provisionArg}" ];
      };
      environment.systemPackages = [ rebuild ];
    }
    (lib.mkIf config.fleet.lockUpdate.enable {
      sops.secrets.github-deploy-key = { };
      systemd.services.nixos-lock-update = {
        description = "Publish nightly flake input updates";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        startAt = "01:00";
        environment = {
          HOME = "/var/lib/nixos-lock";
          GIT_SSH_COMMAND = "ssh -i ${config.sops.secrets.github-deploy-key.path} -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes";
        };
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "nixos-lock";
          ExecStart = "${publish}/bin/nixos-lock-update";
        };
      };
      systemd.timers.nixos-lock-update.timerConfig.Persistent = true;
    })
  ];
}
