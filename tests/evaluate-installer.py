#!/usr/bin/env python3
"""Evaluate real fleet defaults and generated custom accounts without touching disks.

Run from the repository root: python3 tests/evaluate-installer.py
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'installer'))
from installer import Profile, host_defaults, hosts, nix
from settings import DESKTOPS, Settings

repo = Path(__file__).resolve().parents[1]
# Force all existing toplevels, including profiles not used for the custom-account checks.
nix(repo, ['eval', '--json', f'path:{repo}#nixosConfigurations', '--apply',
           'cs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.drvPath) cs'], 'fleet evaluation')
for host in hosts(repo):
    defaults = host_defaults(repo, host)
    assert defaults['settings']['hostname'] == host
    print(f'{host}: defaults valid', flush=True)

with tempfile.TemporaryDirectory(prefix='installer-evaluation-') as directory:
    temp = Path(directory)
    matrix = [('hydrogen', 'gnome'), ('hydrogen', 'none'), ('sulfur', 'gnome'), ('sulfur', 'xfce'), ('sulfur', 'none')] + [('gentlemenpupil', d) for d in DESKTOPS]
    for host, desktop in matrix:
        s = Settings(**host_defaults(repo, host)['settings'])
        s.hostname, s.username, s.full_name = 'custom-tower', 'installer_test', 'A "name" ${literal}'
        s.desktop, s.auto_login = desktop, desktop != 'none'
        s.user_password_mode, s.root_password_mode = 'custom', 'user'
        (temp/'settings.nix').write_text(s.to_nix())
        (temp/'disk.nix').write_text(Profile(host, '/dev/disk/by-id/test-system', system_encrypt=True,
                                            home_device='/dev/disk/by-id/test-home', home_encrypt=True).to_nix())
        expression = f'''let f = builtins.getFlake "path:{repo}";
          c = (f.nixosConfigurations.{host}.extendModules {{ modules = [ {temp}/settings.nix {temp}/disk.nix ]; }}).config;
          in {{ drv = c.system.build.toplevel.drvPath; users = builtins.attrNames c.users.users;
            profile = c.fleet.profileName; hostname = c.networking.hostName;
            home = c.users.users.installer_test.home; root = c.users.users.root.hashedPasswordFile;
            password = c.users.users.installer_test.hashedPasswordFile;
            name = c.users.users.installer_test.description;
          }}'''
        result = subprocess.run(['nix', 'eval', '--impure', '--json', '--expr', expression], capture_output=True, text=True)
        if result.returncode and desktop == 'enlightenment' and 'python-efl' in result.stderr and 'not supported' in result.stderr:
            print('enlightenment: blocked by pinned nixpkgs Python/EFL incompatibility', flush=True)
            continue
        if result.returncode:
            raise RuntimeError(result.stderr)
        value = json.loads(result.stdout)
        assert value['profile'] == host and value['hostname'] == s.hostname
        assert value['home'] == '/home/installer_test' and value['name'] == s.full_name
        assert value['root'] == value['password'] == '/persist/secrets/login-password'
        assert ('sheath' in value['users']) == (host not in ('hydrogen', 'sulfur'))
        assert host not in value['users']
        print(f'{host}/{desktop}: custom settings valid', flush=True)
    # Unfree policy must fail transparently, without silently removing profile packages.
    s.allow_unfree = False
    (temp/'settings.nix').write_text(s.to_nix())
    result = subprocess.run(['nix', 'eval', '--impure', '--json', '--expr', expression], capture_output=True, text=True)
    assert result.returncode and 'unfree' in result.stderr.lower(), result.stderr
    print('unfree software conflict blocked', flush=True)
