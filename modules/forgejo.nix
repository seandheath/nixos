# Private forge; deployment and migration instructions: docs/forgejo.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.forgejo;
  forge = config.services.forgejo;
  devices = import ./family/devices.nix;
  runnerEnabled = cfg.runnerConnections != { };
  runnerUser = "forgejo-ci";
  runnerUid = 1102; # 1100/1101 belong to Minecraft/Valheim.
  runnerHome = "/var/lib/forgejo-runner/hydrogen";
  runtime = "/run/user/${toString config.users.users.${runnerUser}.uid}";
  forgeCommand = "${lib.getExe forge.package} --work-path ${forge.stateDir} --config ${forge.customDir}/conf/app.ini";
  runnerRuntime = pkgs.buildEnv {
    name = "hydrogen-actions-runtime";
    # Keep /var writable: fakeNss supplies a symlink into the read-only store.
    pathsToLink = [ "/bin" "/etc" "/usr" ];
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
      mkdir -p var/empty
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
  options.fleet.forgejo = {
    adminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SOPS runtime file for initial sheath administrator creation; null defers bootstrap.";
    };
    runnerConnections = lib.mkOption {
      default = { };
      description = "One repository-scoped Forgejo registration per admitted repository. Empty disables CI.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            uuid = lib.mkOption { type = lib.types.str; };
            tokenFile = lib.mkOption {
              type = lib.types.str;
              description = "SOPS runtime path, never a Nix store file.";
            };
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    {
      services.forgejo = {
        enable = true;
        database = {
          type = "postgres";
          createDatabase = true;
        };
        lfs.enable = true;
        settings = {
          server = {
            DOMAIN = "git.luckyobserver.com";
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
        (pkgs.writeShellScriptBin "forgejo-admin" ''
          exec ${pkgs.util-linux}/bin/runuser -u ${forge.user} -- ${forgeCommand} "$@"
        '')
      ];

      assertions = [
        {
          assertion = lib.all (p: !(lib.hasPrefix "/nix/store/" p)) (
            lib.optional (cfg.adminPasswordFile != null) cfg.adminPasswordFile
            ++ map (c: c.tokenFile) (builtins.attrValues cfg.runnerConnections)
          );
          message = "Forgejo credentials must be runtime files supplied by SOPS, not Nix store paths.";
        }
      ];

      # Keep a consistent copy of ALL state, including Actions artifacts and generated keys.
      # A SQL dump plus the complete stopped state avoids omissions in app-specific exports.
      systemd.services.forgejo-backup = {
        description = "Export a consistent Forgejo database and state for Borg";
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
          FORGEJO_STATE = forge.stateDir;
          FORGEJO_BACKUP = "/var/backup/forgejo";
          FORGEJO_VERSION = forge.package.version;
        };
        script = builtins.readFile ../packages/forgejo-backup.sh;
        postStop = ''
          # ExecStopPost also runs after failure or termination, when a shell trap cannot.
          if [ -e "$RUNTIME_DIRECTORY/restart" ]; then
            systemctl start forgejo.service
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          RuntimeDirectory = "forgejo-backup";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          TimeoutStartSec = "1h";
        };
      };
      systemd.tmpfiles.rules = [ "d /var/backup/forgejo 0700 root root -" ];
    }

    (lib.mkIf (cfg.adminPasswordFile != null) {
      systemd.services.forgejo-bootstrap = {
        description = "Create the initial Forgejo administrator once";
        requires = [ "forgejo.service" ];
        after = [ "forgejo.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          config.services.postgresql.package
          pkgs.coreutils
        ];
        script = ''
          existing=$(psql --dbname=forgejo --tuples-only --no-align \
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
      systemd.services.forgejo-podman = {
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
          ExecStart = "${pkgs.podman}/bin/podman system service --time=0 unix://${runtime}/forgejo-podman.sock";
          Restart = "on-failure";
          UMask = "0077";
          Delegate = true;
        };
      };

      services.forgejo-runner.instances.hydrogen = {
        enable = true;
        # Override the module's rootful runtime wiring; DOCKER_HOST below selects ours.
        runtimes = {
          docker = false;
          podman = false;
          host = false;
        };
        settings = {
          runner = {
            capacity = 1;
            timeout = "3h";
            labels = [ "hydrogen-linux:docker://${image.imageName}:${image.imageTag}" ];
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
          server.connections = lib.mapAttrs (_: c: {
            url = forge.settings.server.ROOT_URL;
            inherit (c) uuid;
          }) cfg.runnerConnections;
        };
        secrets.server.connections = lib.mapAttrs (_: c: {
          token_url = c.tokenFile;
        }) cfg.runnerConnections;
      };
      systemd.services.forgejo-runner-hydrogen = {
        requires = [ "forgejo-podman.service" ];
        after = [
          "forgejo-podman.service"
          "forgejo.service"
        ];
        environment = {
          DOCKER_HOST = "unix://${runtime}/forgejo-podman.sock";
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
          User = runnerUser;
          Group = runnerUser;
          SupplementaryGroups = lib.mkForce [ ];
          UMask = "0077";
        };
      };
    })
  ];
}
