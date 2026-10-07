# nix build --impure --expr 'let f = builtins.getFlake ("path:" + toString ./.); in
#   import ./tests/forgejo-vm.nix { nixpkgs = f.inputs.nixpkgs; system = "x86_64-linux"; }'
{ nixpkgs, system }:
let
  pkgs = import nixpkgs { inherit system; };
in
pkgs.testers.runNixOSTest {
  name = "hydrogen-forgejo";
  nodes = {
    server = { config, lib, ... }: {
      imports = [ ../modules/forgejo.nix ];
      services.postgresql.package = pkgs.postgresql_17;
      services.forgejo.settings.server = {
        ROOT_URL = lib.mkForce "http://192.168.1.1/";
        SSH_LISTEN_HOST = lib.mkForce "192.168.1.1";
      };
      services.nginx = {
        enable = true;
        virtualHosts.server.locations."/".proxyPass = "http://127.0.0.1:3001";
      };
      fleet.forgejo.runnerConnections.test = {
        uuid = "@UUID@";
        tokenFile = "/root/runner-token";
      };
      services.forgejo-runner.instances.hydrogen.settings.container.options =
        lib.mkForce (lib.concatStringsSep " " [
          "--memory=1g --cpus=2 --pids-limit=1024"
          "--volume=/nix/store:/nix/store:ro"
          "--volume=/nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket:ro"
        ]);
      systemd.services.forgejo-runner-hydrogen = {
        # Register at runtime, following Nixpkgs' Forgejo test UUID substitution.
        wantedBy = lib.mkForce [ ];
        preStart = lib.mkAfter ''
          cp --remove-destination ${config.services.forgejo-runner.instances.hydrogen.configFile} ./config.yaml
          chmod u+w ./config.yaml
          ${lib.getExe pkgs.replace-secret} "@UUID@" "$CREDENTIALS_DIRECTORY/UUID" ./config.yaml
          chmod u-w ./config.yaml
        '';
        serviceConfig = {
          ExecStart = lib.mkForce "${lib.getExe config.services.forgejo-runner.package} daemon --config ./config.yaml";
          LoadCredential = [ "UUID:/root/runner-uuid" ];
        };
      };
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.1.1";
          prefixLength = 24;
        }
      ];
      networking.firewall.allowedTCPPorts = [
        80
        2222
      ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.git
        pkgs.jq
        pkgs.openssl
        pkgs.postgresql_17
      ];
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 8192;
      # Builds and the Nix database must survive the restore-and-reboot test together.
      virtualisation.writableStoreUseTmpfs = false;
    };
    client = { lib, ... }: {
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.1.2";
          prefixLength = 24;
        }
      ];
      networking.hosts."192.168.1.1" = [ "server" ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.git
        pkgs.openssh
        pkgs.netcat-openbsd
      ];
    };
  };
  testScript = ''
    import json
    import shlex

    start_all()
    server.wait_for_unit("forgejo.service")
    server.wait_for_unit("nginx.service")
    server.wait_for_open_port(2222, addr="192.168.1.1")
    # Runtime-generated credentials and keys: no private-key fixtures in the repository.
    password = server.succeed("openssl rand -hex 24").strip()
    server.succeed("forgejo-admin admin user create --username sheath --email test@example.invalid "
                   "--admin --must-change-password=false --password " + shlex.quote(password))

    def api(method, path, data):
        return server.succeed("curl --fail-with-body -sS -u " + shlex.quote("sheath:" + password)
                              + " -X " + method + " --json " + shlex.quote(json.dumps(data))
                              + " http://127.0.0.1:3001/api/v1/" + path)

    repo = json.loads(api("POST", "user/repos", {"name": "test", "private": True}))
    assert repo["private"]
    client.fail("curl -fsS http://server/api/v1/repos/sheath/test")
    client.fail("nc -z -w 2 server 3001")
    client.succeed("ssh-keygen -q -t ed25519 -N " + shlex.quote("") + " -f /root/key")
    pubkey = client.succeed("cat /root/key.pub").strip()
    api("POST", "user/keys", {"title": "vm-test", "key": pubkey})
    client.succeed("git init -b main /tmp/repo; git -C /tmp/repo config user.name Test; "
                   "git -C /tmp/repo config user.email test@example.invalid; "
                   "echo payload > /tmp/repo/payload; git -C /tmp/repo add payload; "
                   "git -C /tmp/repo commit -m initial")
    ssh = "GIT_SSH_COMMAND='ssh -i /root/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' "
    client.succeed(ssh + "git -C /tmp/repo push ssh://git@server:2222/sheath/test.git main")
    client.succeed(ssh + "git clone ssh://git@server:2222/sheath/test.git /tmp/clone")
    client.succeed("cmp /tmp/repo/payload /tmp/clone/payload; git -C /tmp/clone fsck --full")
    api("PATCH", "repos/sheath/test", {"has_actions": True})
    registration = json.loads(api("POST", "repos/sheath/test/actions/runners",
                                  {"name": "vm-test", "ephemeral": False}))
    for name in ("token", "uuid"):
        server.succeed("umask 077; printf %s " + shlex.quote(registration[name]) + " > /root/runner-" + name)
    server.succeed("systemctl start forgejo-runner-hydrogen")
    server.wait_for_unit("forgejo-runner-hydrogen.service")
    nix_expr = 'derivation { name = "forgejo-ci-smoke"; system = builtins.currentSystem; ' \
               'builder = (builtins.storePath "${pkgs.bash}") + "/bin/bash"; args = [ "-c" "echo nix-ci > $out" ]; }'
    workflow = {
        "on": {"push": {}},
        "jobs": {"smoke": {
            "runs-on": "hydrogen-linux",
            "steps": [{
                "env": {"CI_TOKEN": "$" + "{{ github.token }}", "CI_SHA": "$" + "{{ github.sha }}"},
                "run": "set -eu\ngit --version\nnode --version\ncurl --version\nnix --version\n"
                       "test ! -e /var/run/docker.sock\ntest ! -e /run/secrets\n"
                       "test ! -e /run/podman\ntest ! -e /run/user/1102/forgejo-podman.sock\n"
                       "test -S /nix/var/nix/daemon-socket/socket\ntest ! -e source\n"
                       "if touch /nix/store/forgejo-write-probe; then exit 1; fi\n"
                       'output=$(nix build --offline --impure --no-link --print-out-paths --expr ' + shlex.quote(nix_expr) + ')\n'
                       'test "$(cat "$output")" = nix-ci\n'
                       'git clone "http://x-access-token:$CI_TOKEN@192.168.1.1/sheath/test.git" source\n'
                       'test "$(git -C source rev-parse HEAD)" = "$CI_SHA"\n'
                       'test "$(cat source/payload)" = payload\n',
            }],
        }},
    }
    client.succeed("mkdir -p /tmp/repo/.forgejo/workflows; printf %s " + shlex.quote(json.dumps(workflow))
                   + " > /tmp/repo/.forgejo/workflows/smoke.yml; git -C /tmp/repo add .; "
                   "git -C /tmp/repo commit -m workflow")
    client.succeed(ssh + "git -C /tmp/repo push ssh://git@server:2222/sheath/test.git main")

    def jobs_passed(count):
        tasks = json.loads(api("GET", "repos/sheath/test/actions/tasks", {}))["workflow_runs"]
        statuses = [task["status"] for task in tasks]
        if "failure" in statuses:
            server.log(server.succeed("find /var/lib/forgejo/data/actions_log -type f -name '*.log.zst' -exec ${pkgs.zstd}/bin/zstd -dc {} +"))
        assert "failure" not in statuses, statuses
        return len(statuses) >= count and all(status == "success" for status in statuses)

    retry(lambda _: jobs_passed(1), 180)
    server.succeed("systemctl start forgejo-backup.service")
    server.wait_for_unit("forgejo.service")
    server.succeed("tar -tf /var/backup/forgejo/forgejo.tar | grep database.dump")
    server.succeed("tar -tf /var/backup/forgejo/forgejo.tar | grep custom/conf/secret_key")
    # A failed export must resume the forge and preserve the last complete backup.
    digest = server.succeed("sha256sum /var/backup/forgejo/forgejo.tar")
    server.succeed("mkdir -p /run/systemd/system/forgejo-backup.service.d; "
                   "printf '[Service]\\nEnvironment=FORGEJO_STATE=/missing\\n' "
                   "> /run/systemd/system/forgejo-backup.service.d/fail.conf; systemctl daemon-reload")
    server.fail("systemctl start forgejo-backup.service")
    server.wait_for_unit("forgejo.service")
    assert server.succeed("sha256sum /var/backup/forgejo/forgejo.tar") == digest
    server.succeed("rm /run/systemd/system/forgejo-backup.service.d/fail.conf; systemctl daemon-reload; "
                   "systemctl reset-failed forgejo-backup.service; systemctl start forgejo-backup.service")
    server.wait_for_unit("forgejo.service")
    # Restore into an empty database/state directory on this disposable VM.
    secret_hash = server.succeed("sha256sum /var/lib/forgejo/custom/conf/secret_key")
    server.succeed("systemctl stop forgejo; mkdir /tmp/restore; "
                   "tar -xf /var/backup/forgejo/forgejo.tar -C /tmp/restore; "
                   "mv /var/lib/forgejo /var/lib/forgejo.before-restore; "
                   "mkdir /var/lib/forgejo; cp -a /tmp/restore/state/. /var/lib/forgejo/; "
                   "chown -R forgejo:forgejo /var/lib/forgejo; "
                   "runuser -u postgres -- dropdb forgejo; "
                   "runuser -u postgres -- createdb --owner=forgejo forgejo; "
                   "runuser -u forgejo -- pg_restore --exit-on-error --no-owner --dbname=forgejo "
                   "< /tmp/restore/database.dump; systemctl start forgejo")
    server.wait_for_unit("forgejo.service")
    assert server.succeed("sha256sum /var/lib/forgejo/custom/conf/secret_key") == secret_hash
    server.shutdown()
    server.start()
    server.wait_for_unit("forgejo.service")
    client.succeed(ssh + "git clone ssh://git@server:2222/sheath/test.git /tmp/restored")
    client.succeed("cmp /tmp/repo/payload /tmp/restored/payload; git -C /tmp/restored fsck --full")
    server.succeed("systemctl start forgejo-runner-hydrogen")
    client.succeed("git -C /tmp/repo commit --allow-empty -m retrigger")
    client.succeed(ssh + "git -C /tmp/repo push ssh://git@server:2222/sheath/test.git main")
    retry(lambda _: jobs_passed(2), 180)
  '';
}
