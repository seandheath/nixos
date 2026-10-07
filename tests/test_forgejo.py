"""Offline checks: python3 tests/test_forgejo.py /path/to/pinned/nixpkgs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

root = Path(__file__).resolve().parents[1]
env = dict(os.environ, FORGEJO_TEST_NIXPKGS=sys.argv[1], FORGEJO_TEST_ROOT=str(root))
expression = '''
let
  base = import (builtins.getEnv "FORGEJO_TEST_NIXPKGS" + "/nixos/lib/eval-config.nix") {
    modules = [ (builtins.getEnv "FORGEJO_TEST_ROOT" + "/modules/forgejo.nix") {
      boot.isContainer = true;
      system.stateVersion = "25.11";
      nixpkgs.hostPlatform = "x86_64-linux";
    } ];
  };
  enabled = base.extendModules { modules = [{
    fleet.forgejo = {
      adminPasswordFile = "/run/secrets/test-admin";
      runnerConnections.test = {
        uuid = "00000000-0000-0000-0000-000000000000";
        tokenFile = "/run/secrets/test-runner";
      };
    };
  }]; };
  c = enabled.config;
in {
  failures = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
  inactive = builtins.attrNames base.config.services.forgejo-runner.instances;
  forge = c.services.forgejo.settings;
  runner = c.services.forgejo-runner.instances.hydrogen.settings;
  service = c.systemd.services.forgejo-runner-hydrogen.serviceConfig;
  podman = c.systemd.services.forgejo-podman.serviceConfig;
  backup = c.systemd.services.forgejo-backup.script;
  restart = c.systemd.services.forgejo-backup.postStop;
  bootstrap = c.systemd.services.forgejo-bootstrap.script;
  forgeExecutable = base.pkgs.lib.getExe c.services.forgejo.package;
}
'''
result = subprocess.run(
    ["nix-instantiate", "--eval", "--strict", "--json", "--store", "dummy://", "--expr", expression],
    env=env, text=True, capture_output=True, check=True,
)
config = json.loads(result.stdout)
assert not config["failures"], config["failures"]
assert config["inactive"] == []
assert config["forge"]["repository"]["FORCE_PRIVATE"]
assert config["forge"]["service"]["DISABLE_REGISTRATION"]
assert config["forge"]["service"]["REQUIRE_SIGNIN_VIEW"]
assert config["forge"]["session"]["COOKIE_SECURE"]
assert config["forge"]["server"]["HTTP_ADDR"] == "127.0.0.1"
assert config["forge"]["server"]["SSH_LISTEN_HOST"] == "100.64.0.3"
assert config["forge"]["server"]["BUILTIN_SSH_SERVER_USER"] == "git"
assert config["forge"]["mirror"]["DISABLE_NEW_PUSH"]
assert config["runner"]["runner"]["capacity"] == 1
assert all(":docker://" in label for label in config["runner"]["runner"]["labels"])
assert config["runner"]["container"]["docker_host"] == "-"
assert config["runner"]["container"]["valid_volumes"] == []
assert not config["runner"]["container"]["privileged"]
assert config["runner"]["container"]["network"] != "host"
assert config["service"]["User"] == config["podman"]["User"] == "forgejo-ci"
assert config["service"]["SupplementaryGroups"] == []
assert config["service"]["LoadCredential"] == ["server__connections__test__token_url:/run/secrets/test-runner"]

with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    for name in ("bin", "state", "backup", "runtime"):
        (temp / name).mkdir()
    for name in ("custom/conf/secret_key", "data/lfs/object", "data/actions/artifacts/object"):
        path = temp / "state" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("test-only state: " + name)
    (temp / "state/lfs-link").symlink_to("data/lfs/object")
    (temp / "state/absolute-link").symlink_to("/test-only/external-path")
    (temp / "state/lfs-hardlink").hardlink_to(temp / "state/data/lfs/object")
    mocks = {
        "systemctl": '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
p = Path(os.environ["RUNTIME_DIRECTORY"])
with (p / "calls").open("a") as f: f.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1] == "is-active": sys.exit(0 if (p / "active").exists() else 3)
if sys.argv[1] == "stop": (p / "active").unlink()
if sys.argv[1] == "start": (p / "active").touch()
''',
        "runuser": '''#!/bin/sh
[ "$1" = -u ] && [ "$2" = forgejo ] && [ "$3" = -- ] || exit 2
shift 3
exec "$@"
''',
        "pg_dump": '''#!/bin/sh
[ "$1" = --format=custom ] && [ "$2" = forgejo ] || exit 2
[ "${FAIL_DUMP:-0}" = 0 ] || exit 1
printf 'test-only database dump'
''',
        "psql": '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if os.environ.get("FAIL_QUERY"): sys.exit(1)
if Path(os.environ["RUNTIME_DIRECTORY"], "user-created").exists(): print(1)
''',
        "forgejo": '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
assert "create" in sys.argv and "--admin" in sys.argv
assert sys.argv[sys.argv.index("--username") + 1] == "sheath"
assert sys.argv[sys.argv.index("--password") + 1] == Path(os.environ["CREDENTIALS_DIRECTORY"], "password").read_text()
p = Path(os.environ["RUNTIME_DIRECTORY"], "user-created")
assert not p.exists(), "bootstrap must not reset an existing user"
p.touch()
''',
    }
    for name, content in mocks.items():
        path = temp / "bin" / name
        path.write_text(content)
        path.chmod(0o700)
    test_env = dict(os.environ, PATH=str(temp / "bin") + ":" + os.environ["PATH"],
                    FORGEJO_STATE=str(temp / "state"), FORGEJO_BACKUP=str(temp / "backup"),
                    RUNTIME_DIRECTORY=str(temp / "runtime"), FORGEJO_VERSION="test-only")
    (temp / "runtime/active").touch()

    def export(**overrides):
        # systemd invokes ExecStopPost even when ExecStart exits unsuccessfully.
        (temp / "runtime/restart").unlink(missing_ok=True)
        execution_env = dict(test_env, **overrides)
        run = subprocess.run(["bash", "-ec", config["backup"]], env=execution_env, capture_output=True)
        subprocess.run(["bash", "-ec", config["restart"]], env=execution_env, check=True)
        return run.returncode

    assert export() == 0
    archive = temp / "backup/forgejo.tar"
    original = archive.read_bytes()
    assert archive.stat().st_mode & 0o777 == 0o600
    with tarfile.open(archive) as contents:
        assert contents.extractfile("database.dump").read() == b"test-only database dump"
        assert contents.extractfile("VERSION").read() == b"test-only\n"
        assert contents.getmember("state/./lfs-link").linkname == "data/lfs/object"
        assert contents.getmember("state/./absolute-link").linkname == "/test-only/external-path"
        assert contents.extractfile("state/./lfs-hardlink").read() == (temp / "state/data/lfs/object").read_bytes()
        for name in ("custom/conf/secret_key", "data/lfs/object", "data/actions/artifacts/object"):
            assert contents.extractfile("state/./" + name).read() == (temp / "state" / name).read_bytes()
    for failure in ({"FAIL_DUMP": "1"}, {"FORGEJO_STATE": str(temp / "missing")}):
        assert export(**failure) != 0
        assert archive.read_bytes() == original
        assert (temp / "runtime/active").exists()
        assert not list((temp / "backup").glob(".partial.*"))
    (temp / "runtime/active").unlink()
    assert export() != 0
    assert not (temp / "runtime/active").exists()  # Intentionally stopped stays stopped.
    assert archive.read_bytes() == original

    # Execute the generated bootstrap control flow against a tiny fake CLI/database.
    bootstrap = config["bootstrap"].replace(config["forgeExecutable"], str(temp / "bin/forgejo"))
    (temp / "runtime/password").write_text("test-only password fixture")
    bootstrap_env = dict(test_env, CREDENTIALS_DIRECTORY=str(temp / "runtime"))
    for _ in range(2):
        subprocess.run(["bash", "-ec", bootstrap], env=bootstrap_env, check=True)
    (temp / "runtime/user-created").unlink()
    failed = subprocess.run(["bash", "-ec", bootstrap], env=dict(bootstrap_env, FAIL_QUERY="1"))
    assert failed.returncode != 0
    assert not (temp / "runtime/user-created").exists()

print("Forgejo configuration, create-once bootstrap and atomic backup/failure recovery checks passed")
