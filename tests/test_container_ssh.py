"""Run: python3 tests/test_container_ssh.py /path/to/pinned/nixpkgs."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
expression = f'import {root}/packages/container-ssh.nix {{ pkgs = import {Path(sys.argv[1]).resolve()} {{}}; }}'
script = json.loads(subprocess.check_output(
    ["nix-instantiate", "--eval", "--strict", "--json", "--store", "dummy://", "--expr", expression], text=True,
))
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory)
    (home / ".ssh").mkdir()
    public = home / "public identity"
    public.write_text("public identity fixture\n")
    (home / ".ssh/personal.pub").symlink_to(public)
    env = dict(os.environ, HOME=str(home))

    def arguments(agent):
        env["SSH_AUTH_SOCK"] = agent
        result = subprocess.check_output(
            ["bash", "-eu", "-c", script + '\nprintf "%s\\0" "${sshagent_args[@]}"'], env=env,
        )
        return result.decode().rstrip("\0").split("\0")

    expected = ["--add-host=git.luckyobserver.com:100.64.0.3",
                "-v", "/run/secrets/remote-coding:/run/secrets/remote-coding:ro"]
    assert arguments("") == expected
    assert arguments(str(home / "missing-agent")) == expected
    (home / "not-a-socket").touch()
    assert arguments(str(home / "not-a-socket")) == expected
    with socket.socket(socket.AF_UNIX) as agent:
        agent.bind(str(home / "agent"))
        args = arguments(str(home / "agent"))
        assert str(home / "agent") + ":/run/ssh-agent.sock:ro" in args
        assert "SSH_AUTH_SOCK=/run/ssh-agent.sock" in args
        assert str(public) + ":/run/forgejo-identity.pub:ro" in args
        assert any(a.startswith("GIT_SSH_COMMAND=ssh -F /nix/store/") for a in args)
        assert not any("personal:" in a or "/.ssh:" in a for a in args)
        (home / ".ssh/personal.pub").unlink()
        args = arguments(str(home / "agent"))
        assert "SSH_AUTH_SOCK=/run/ssh-agent.sock" in args
        assert not any("forgejo-identity" in a or "GIT_SSH_COMMAND" in a for a in args)
print("Container SSH socket, public identity and missing-agent checks passed")
