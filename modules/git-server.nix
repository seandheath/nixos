# Private bare git repositories on hydrogen, served by sshd over WireGuard.
#
# No daemon, no database, no web surface: the `git` account's shell IS git-shell, so a key
# that reaches sshd can run git-upload-pack and git-receive-pack and nothing else. The
# repos are plain directories, so a Borg restore hands them back working.
#
# CLI, root only: git-repo create|list|delete.
{ config, lib, pkgs, ... }:
let
  cfg = config.fleet.gitServer;

  gitRepoCli = pkgs.writeShellScriptBin "git-repo" ''
    set -eu
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.git pkgs.sudo ]}
    repos=${lib.escapeShellArg cfg.repoDir}

    if [ "$(id -u)" -ne 0 ]; then
      echo "git-repo must run as root." >&2
      exit 2
    fi

    usage() {
      echo "usage: git-repo create <name> | list | delete <name>" >&2
      exit 2
    }

    # Rejects path separators, leading dots and everything else that could escape $repos.
    check_name() {
      case "$1" in
        *[!A-Za-z0-9._-]* | "" | .*)
          echo "git-repo: invalid repository name: $1" >&2
          echo "Allowed: letters, digits, dot, dash, underscore; no leading dot." >&2
          exit 2
          ;;
      esac
    }

    case "''${1-}" in
      create)
        [ "$#" -eq 2 ] || usage
        check_name "$2"
        dir="$repos/$2.git"
        if [ -e "$dir" ]; then
          echo "git-repo: $dir already exists." >&2
          exit 1
        fi
        install -d -o git -g git -m 0750 "$dir"
        sudo -u git git init --bare --initial-branch=main "$dir" >/dev/null
        echo "Created $dir"
        echo "  git clone hydrogen-git:$2.git   # the sulfur alias"
        ;;

      list)
        [ "$#" -eq 1 ] || usage
        found=0
        for dir in "$repos"/*.git; do
          [ -d "$dir" ] || continue
          found=1
          name=$(basename "$dir" .git)
          last=$(sudo -u git git -C "$dir" log -1 --format=%cs 2>/dev/null || echo "empty")
          printf '%-30s %s\n' "$name" "$last"
        done
        [ "$found" -eq 1 ] || echo "No repositories in $repos."
        ;;

      delete)
        [ "$#" -eq 2 ] || usage
        check_name "$2"
        dir="$repos/$2.git"
        [ -d "$dir" ] || { echo "git-repo: no such repository: $2" >&2; exit 1; }
        echo "This deletes $dir and every commit in it. There is no undo here;"
        echo "the only other copy is whatever last night's Borg run took."
        printf 'Type the repository name to confirm: '
        read -r confirm
        [ "$confirm" = "$2" ] || { echo "Aborted." >&2; exit 1; }
        rm -rf -- "$dir"
        echo "Deleted $dir"
        ;;

      *) usage ;;
    esac
  '';
in
{
  options.fleet.gitServer = {
    enable = lib.mkEnableOption "private bare git repositories served over SSH";

    repoDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/git";
      description = "Directory holding the bare repositories. Must be in backupPaths.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = (import ../users/sheath.nix).openssh.authorizedKeys.keys;
      description = ''
        Keys allowed to push and fetch. Defaults to sheath's own, read from
        users/sheath.nix so the key stays in one place.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.git = { };
    users.users.git = {
      isSystemUser = true;
      group = "git";
      home = cfg.repoDir;
      createHome = true;
      # Also the mode of the repo root; a second tmpfiles rule for the same directory
      # would just be a second owner of one fact.
      homeMode = "0750";
      description = "git repository owner";
      # The confinement. No ~/git-shell-commands directory exists, so an interactive login
      # is refused outright rather than dropping to a restricted menu.
      shell = "${pkgs.git}/bin/git-shell";
      openssh.authorizedKeys.keys = map (
        k: "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty ${k}"
      ) cfg.authorizedKeys;
    };

    environment.systemPackages = [ gitRepoCli ];

    assertions = [{
      assertion = config.services.openssh.enable;
      message = "fleet.gitServer needs services.openssh.enable -- SSH is the only transport.";
    }];
  };
}
