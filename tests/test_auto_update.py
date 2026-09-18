"""Run: python3 tests/test_auto_update.py. Uses a local Git remote; never rebuilds a host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
flake = f"path:{root}#nixosConfigurations"


def run(*args, ok=True, env=None):
    result = subprocess.run(args, text=True, capture_output=True, env=env)
    assert (result.returncode == 0) == ok, result.stdout + result.stderr
    return result.stdout


settings = json.loads(run("nix", "eval", "--json", flake, "--apply", '''hosts:
  builtins.mapAttrs (_: h: {
    upgrade = h.config.system.autoUpgrade;
    enabled = h.config.systemd.timers.nixos-upgrade.enable;
    prepare = builtins.head h.config.systemd.services.nixos-upgrade.serviceConfig.ExecStartPre;
    dependencies = builtins.attrNames (builtins.getContext
      (builtins.head h.config.systemd.services.nixos-upgrade.serviceConfig.ExecStartPre));
  }) hosts'''))
assert not settings["sulfur"]["enabled"]
for name, host in settings.items():
    assert host["upgrade"]["enable"] and not host["upgrade"]["upgrade"]
    assert host["upgrade"]["allowReboot"] == (name == "hydrogen")
assert settings["hydrogen"]["upgrade"]["rebootWindow"] == {"lower": "05:00", "upper": "06:00"}
run("nix-store", "--realise", *settings["hydrogen"]["dependencies"])
prepare = settings["hydrogen"]["prepare"].split()[0]

with tempfile.TemporaryDirectory() as directory:
    temp = Path(directory)
    upstream, checkout, provision = (temp / name for name in ("upstream", "checkout", "provision"))
    run("git", "init", "-b", "main", str(upstream))
    (upstream / "flake.nix").write_text('''{ outputs = { self }: {
      nixosConfigurations.hydrogen.config.fleet.hardware.isPlaceholder =
        !(builtins.pathExists ./provisioning/hydrogen/hardware.nix);
    }; }''')
    (upstream / "flake.lock").write_text('{"nodes":{"root":{}},"root":"root","version":7}')
    run("git", "-C", str(upstream), "add", ".")
    run("git", "-C", str(upstream), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial")
    env = dict(os.environ, GIT_CONFIG_COUNT="1",
               GIT_CONFIG_KEY_0=f"url.{upstream}.insteadOf",
               GIT_CONFIG_VALUE_0="https://github.com/seandheath/nixos.git")
    run(prepare, str(checkout), ok=False, env=env)  # Placeholder hardware.
    provision.mkdir()
    run(prepare, str(checkout), str(provision), ok=False, env=env)  # Missing local facts.
    for name in ("default.nix", "disk.nix", "hardware.nix", "settings.nix"):
        (provision / name).write_text("{ ... }: {}\n")
    run(prepare, str(checkout), str(provision), env=env)
    target = checkout / "provisioning/hydrogen"
    assert (target / "hardware.nix").stat().st_mode & 0o777 == 0o600
    (provision / "settings.nix").unlink()
    run(prepare, str(checkout), str(provision), env=env)
    assert not (target / "settings.nix").exists()
print("Native update settings and provisioning checks passed")
