"""Run: python3 tests/test_agent_launchers.py /path/to/pinned/nixpkgs.

Evaluates the actual Nix launchers; records CLI/Podman calls without running agents.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
expression = r'''
let
  root = ROOT;
  pkgs = import NIXPKGS { system = "x86_64-linux"; overlays = [ (import (root + "/packages")) ]; };
  config.fleet.adminUser = "test";
  oc = import (root + "/modules/opencode.nix") { inherit config pkgs; inherit (pkgs) lib; };
  container = import (root + "/modules/re-container.nix") { inherit pkgs; };
  hmConfig = {
    home.homeDirectory = "/home/test";
    sops.placeholder = { openwebui-url = "https://example.invalid/v1"; openwebui-model = "test-model"; openwebui-api-key = "test-key"; };
  };
in {
  scripts = {
    opencode = (builtins.head oc.environment.systemPackages).text;
    copencode = (builtins.elemAt container.environment.systemPackages 1).text;
  };
  paths = {
    podman = "${pkgs.podman}/bin/podman";
    opencode = "${pkgs.opencode}/bin/opencode";
  };
  configs = (builtins.head oc.home-manager.users.test.imports {config = hmConfig; inherit (pkgs) lib;}).sops.templates;
}'''.replace("ROOT", str(root)).replace("NIXPKGS", str(Path(sys.argv[1]).resolve()))
evaluated = subprocess.run(
    ["nix-instantiate", "--eval", "--strict", "--json", "--store", "dummy://", "--expr", expression],
    text=True, capture_output=True, check=True,
)
data = json.loads(evaluated.stdout)
configs = {name: json.loads(value["content"]) for name, value in data["configs"].items()}
assert "mcp" not in configs["opencode.json"] and "agent" not in configs["opencode.json"]
assert configs["opencode-re.json"]["default_agent"] == "re"
assert configs["opencode-re.json"]["mcp"]["reva"]["enabled"]
assert "permission" not in configs["opencode.json"]
assert configs["opencode-re.json"]["agent"]["re"]["permission"]["bash"]["*"] == "ask"
assert configs["opencode-container.json"]["permission"] == "allow"
assert configs["opencode-container-re.json"]["agent"]["re"]["permission"] == "allow"

with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    home = temp / "home"
    stub = temp / "record"
    stub.write_text(f'''#!{sys.executable}
import json, os, sys
if sys.argv[1:3] == ["image", "exists"]: sys.exit(0)
print(json.dumps({{"args": sys.argv[1:], "env": {{k: os.environ.get(k) for k in
    ["OPENCODE_CONFIG", "OPENWEBUI_URL", "OPENWEBUI_MODEL", "OPENWEBUI_API_KEY"]}}}}))
''')
    stub.chmod(0o755)
    for name in [".config/opencode/AGENTS.md", ".config/opencode/re-instructions.md",
                 ".config/opencode/skills/datasheet-reference/SKILL.md"]:
        file = home / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("test\n")
    for name in configs:
        (home / ".config/opencode" / name).write_text(json.dumps(configs[name]))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("OPENCODE_", "OPENWEBUI_"))}
    env["HOME"] = str(home)
    for name, script in data["scripts"].items():
        for path_name, path in data["paths"].items():
            if path_name in ["opencode", "podman"]:
                script = script.replace(path, str(stub))
        # Nix interpolates these source paths as store copies; run the repository files.
        script = re.sub(r"/nix/store/[a-z0-9]+-reva-flag\.sh", str(root / "packages/reva-flag.sh"), script)
        script = re.sub(r"/nix/store/[a-z0-9]+-container-devices\.sh", str(root / "packages/container-devices.sh"), script)
        (temp / name).write_text(script)
        subprocess.run(["bash", "-n", str(temp / name)], check=True)

    def launch(name, *args, ok=True):
        result = subprocess.run(["bash", str(temp / name), *args], cwd=temp, env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == ok, (name, args, result.stdout, result.stderr)
        return json.loads(result.stdout) if ok else result.stderr

    def network(call):
        return next(arg for arg in call["args"] if arg.startswith("--network="))

    assert "/run/secrets/remote-coding:/run/secrets/remote-coding:ro" in launch("copencode", "run", "hello")["args"]
    assert launch("opencode", "--reva", "run", "hello")["env"]["OPENCODE_CONFIG"] == str(home / ".config/opencode/opencode-re.json")
    assert launch("opencode", "run", "hello")["env"]["OPENCODE_CONFIG"] is None
    assert launch("opencode", "--", "--reva")["args"] == ["--", "--reva"]

    oc = launch("copencode", "run", "hello")
    assert network(oc) == "--network=pasta:-T,none"
    assert any("opencode-container.json:" in arg for arg in oc["args"])
    assert not any("re-instructions" in arg or ".qwen" in arg for arg in oc["args"])
    oc_re = launch("copencode", "--reva")
    assert network(oc_re) == "--network=pasta:-T,8080"
    assert any("opencode-container-re.json:" in arg for arg in oc_re["args"])
    assert "--reva" not in oc_re["args"]
    (home / ".config/opencode/skills/datasheet-reference/SKILL.md").unlink()
    assert "configuration missing" in launch("copencode", "--reva", ok=False)

print("Agent launcher and configuration checks passed")
