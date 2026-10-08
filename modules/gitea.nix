# Private forge; deployment and migration instructions: docs/gitea.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.gitea;
  forge = config.services.gitea;
  devices = import ./family/devices.nix;
  runnerEnabled = cfg.runnerTokenFile != null;
  runnerUser = "gitea-ci";
  runnerUid = 1102; # 1100/1101 belong to Minecraft/Valheim.
  runnerHome = "/var/lib/gitea-runner/hydrogen";
  runtime = "/run/user/${toString config.users.users.${runnerUser}.uid}";
  forgeCommand = "${lib.getExe forge.package} --work-path ${forge.stateDir} --config ${forge.customDir}/conf/app.ini";
  logReader = pkgs.writeShellScript "gitea-read-log" ''
    set -euo pipefail
    if [[ $# != 1 || ! $1 =~ ^([A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*)\ ([1-9][0-9]*)$ ]]; then
      echo 'Usage: ssh ci-logs@hydrogen "owner/repo TASK_ID"' >&2
      exit 2
    fi
    repo=''${BASH_REMATCH[1]}
    task=''${BASH_REMATCH[2]}
    shopt -s nullglob
    logs=(${lib.escapeShellArg "${forge.stateDir}/data/actions_log"}/"$repo"/[0-9a-f][0-9a-f]/"$task".log.zst)
    if [[ ''${#logs[@]} != 1 ]]; then
      echo 'No completed log found for that repository and task ID.' >&2
      exit 1
    fi
    log=''${logs[0]}
    if [[ $(${pkgs.coreutils}/bin/realpath -e -- "$log") != "$log" ]]; then
      echo 'Refusing a log path containing a symbolic link.' >&2
      exit 1
    fi
    exec ${pkgs.zstd}/bin/zstd -dc -- "$log"
  '';
  logSsh = pkgs.writeShellScript "gitea-log-ssh" ''
    exec /run/wrappers/bin/sudo -n -u ${forge.user} -- ${logReader} "$SSH_ORIGINAL_COMMAND"
  '';
  runnerRuntime = pkgs.buildEnv {
    name = "hydrogen-actions-runtime";
    # Keep /var writable: fakeNss supplies a symlink into the read-only store.
    pathsToLink = [ "/bin" "/etc" "/etc/ssl/certs" "/usr" ];
    paths = with pkgs; [
      bashInteractive
      coreutils
      curl
      findutils
      gawk
      git
      gnugrep
      gnused
      gnutar
      gzip
      jq
      config.nix.package
      nodejs
      openssh
      cacert
      dockerTools.usrBinEnv
      dockerTools.fakeNss
    ];
  };
  # Nix's content-derived image tag changes with the closure, without a floating registry tag.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/hydrogen-actions";
    contents = [ runnerRuntime ];
    extraCommands = ''
      mkdir -m 1777 tmp
      mkdir -p var/empty etc/ssl/certs lib64
      ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
      ln -s ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2
    '';
    config.Env = [
      "PATH=/bin:/usr/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_REMOTE=daemon"
      "NIX_CONFIG=experimental-features = nix-command flakes"
    ];
  };
in
{
  options.fleet.gitea = {
    adminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SOPS runtime file for initial sheath administrator creation; null defers bootstrap.";
    };
    runnerTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Runtime environment file containing TOKEN for Gitea runner registration; null disables CI.";
    };
  };

  config = lib.mkMerge [
    {
      services.gitea = {
        enable = true;
        database = {
          type = "postgres";
          createDatabase = true;
        };
        lfs.enable = true;
        settings = {
          server = {
            ROOT_URL = "https://git.luckyobserver.com/";
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = 3001;
            START_SSH_SERVER = true;
            SSH_DOMAIN = "git.luckyobserver.com";
            BUILTIN_SSH_SERVER_USER = "git";
            SSH_LISTEN_HOST = devices.hydrogen.tailAddress;
            SSH_LISTEN_PORT = 2222;
            SSH_PORT = 2222;
          };
          service = {
            DISABLE_REGISTRATION = true;
            REQUIRE_SIGNIN_VIEW = true;
          };
          repository = {
            FORCE_PRIVATE = true;
            DEFAULT_PRIVATE = "private";
            DEFAULT_BRANCH = "main";
            # Repositories opt into Actions explicitly after runner admission.
            DEFAULT_REPO_UNITS = "repo.code,repo.issues,repo.pulls,repo.releases";
          };
          mirror = {
            ENABLED = false;
            DISABLE_NEW_PUSH = true;
            DISABLE_NEW_PULL = true;
          };
          actions.ENABLED = true;
          session.COOKIE_SECURE = true;
        };
      };

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "gitea-admin" ''
          exec ${pkgs.util-linux}/bin/runuser -u ${forge.user} -- ${forgeCommand} "$@"
        '')
      ];

      users.groups.ci-logs = { };
      users.users.ci-logs = {
        isSystemUser = true;
        group = "ci-logs";
        home = "/var/empty";
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = map (
          key: "from=\"100.64.0.0/10\" ${key}"
        ) (import ../users/sheath.nix).openssh.authorizedKeys.keys;
      };
      services.openssh.extraConfig = ''
        Match User ci-logs
          ForceCommand ${logSsh}
          AuthenticationMethods publickey
          DisableForwarding yes
          PermitTTY no
          PermitUserRC no
        Match all
      '';
      security.sudo.extraRules = [{
        users = [ "ci-logs" ];
        runAs = forge.user;
        commands = [{ command = "${logReader} *"; options = [ "NOPASSWD" ]; }];
      }];

      assertions = [
        {
          assertion = lib.all (p: !(lib.hasPrefix "/nix/store/" p)) (
            lib.optional (cfg.adminPasswordFile != null) cfg.adminPasswordFile
            ++ lib.optional (cfg.runnerTokenFile != null) cfg.runnerTokenFile
          );
          message = "Gitea credentials must be runtime files supplied by SOPS, not Nix store paths.";
        }
      ];

      # Keep a consistent copy of ALL state, including Actions artifacts and generated keys.
      # A SQL dump plus the complete stopped state avoids omissions in app-specific exports.
      systemd.services.gitea-backup = {
        description = "Export a consistent Gitea database and state for Borg";
        requires = [ "postgresql.service" ];
        after = [ "postgresql.service" ];
        path = with pkgs; [
          coreutils
          gnutar
          systemd
          util-linux
          config.services.postgresql.package
        ];
        environment = {
          GITEA_STATE = forge.stateDir;
          GITEA_BACKUP = "/var/backup/gitea";
          GITEA_VERSION = forge.package.version;
        };
        script = builtins.readFile ../packages/gitea-backup.sh;
        postStop = ''
          # ExecStopPost also runs after failure or termination, when a shell trap cannot.
          if [ -e "$RUNTIME_DIRECTORY/restart" ]; then
            systemctl start gitea.service
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "gitea-backup";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = "1h";
        };
      };
      systemd.tmpfiles.rules = [ "d /var/backup/gitea 0700 root root -" ];
    }

    (lib.mkIf (cfg.adminPasswordFile != null) {
      systemd.services.gitea-bootstrap = {
        description = "Create the initial Gitea administrator once";
        requires = [ "gitea.service" ];
        after = [ "gitea.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          config.services.postgresql.package
          pkgs.coreutils
        ];
        script = ''
          existing=$(psql --dbname=gitea --tuples-only --no-align \
            --command="SELECT 1 FROM \"user\" WHERE lower_name = 'sheath';")
          if [ "$existing" != 1 ]; then
            ${forgeCommand} admin user create --username sheath --email se@nheath.com \
              --admin --password "$(cat "$CREDENTIALS_DIRECTORY/password")"
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          User = forge.user;
          Group = forge.group;
          LoadCredential = [ "password:${cfg.adminPasswordFile}" ];
          UMask = "0077";
        };
      };
    })

    (lib.mkIf runnerEnabled {
      # The host store hides the image's copy; retain its command targets across GC.
      system.extraDependencies = [ runnerRuntime ];
      boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
      virtualisation.podman.enable = true;
      users.groups.${runnerUser} = { };
      users.users.${runnerUser} = {
        isNormalUser = true; # Allocates subuid/subgid ranges for rootless Podman.
        uid = runnerUid;
        group = runnerUser;
        home = runnerHome;
        createHome = true;
        homeMode = "0700";
        linger = true;
      };

      # A system unit under the dedicated uid, never the privileged system Podman socket.
      systemd.services.gitea-podman = {
        path = [ "/run/wrappers" ]; # Rootless subordinate IDs require setuid newuidmap/newgidmap.
        requires = [ "user@${toString runnerUid}.service" ];
        after = [ "user@${toString runnerUid}.service" ];
        environment = {
          HOME = runnerHome;
          XDG_RUNTIME_DIR = runtime;
          DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtime}/bus";
        };
        serviceConfig = {
          User = runnerUser;
          Group = runnerUser;
          ExecStart = "${pkgs.podman}/bin/podman system service --time=0 unix://${runtime}/gitea-podman.sock";
          Restart = "on-failure";
          UMask = "0077";
          Delegate = true;
        };
      };

      services.gitea-actions-runner.instances.hydrogen = {
        enable = true;
        name = "hydrogen";
        url = forge.settings.server.ROOT_URL;
        tokenFile = cfg.runnerTokenFile;
        labels = [ "hydrogen-linux:docker://${image.imageName}:${image.imageTag}" ];
        settings = {
          runner = {
            capacity = 1;
            timeout = "3h";
          };
          cache.enabled = false;
          container = {
            network = "";
            privileged = false;
            valid_volumes = [ "/nix/store" "/nix/var/nix/daemon-socket" ];
            docker_host = "-"; # Use DOCKER_HOST without mounting its socket inside jobs.
            force_pull = false;
            options = lib.concatStringsSep " " [
              "--memory=8g --cpus=4 --pids-limit=1024"
              "--add-host=git.luckyobserver.com:${devices.hydrogen.tailAddress}"
              "--volume=/nix/store:/nix/store:ro"
              "--volume=/nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket:ro"
            ];
          };
        };
      };
      systemd.services.gitea-runner-hydrogen = {
        requires = [ "gitea-podman.service" ];
        after = [
          "gitea-podman.service"
          "gitea.service"
        ];
        environment = {
          DOCKER_HOST = lib.mkForce "unix://${runtime}/gitea-podman.sock";
          XDG_RUNTIME_DIR = runtime;
        };
        path = [ pkgs.podman ];
        preStart = ''
          # Starting the process does not promise that its API socket accepts requests yet.
          for attempt in $(seq 1 30); do
            if podman --remote --url "$DOCKER_HOST" info >/dev/null 2>&1; then break; fi
            sleep 1
          done
          podman --remote --url "$DOCKER_HOST" load --input ${image}
        '';
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = lib.mkForce runnerUser;
          Group = runnerUser;
          SupplementaryGroups = lib.mkForce [ ];
          UMask = "0077";
        };
      };
    })
  ];
}
