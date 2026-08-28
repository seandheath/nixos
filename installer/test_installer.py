"""Unit tests for installer decisions that do not need a live ISO."""

import json
import tempfile
import unittest
import inspect
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from installer import Board, Profile, UNSET_DEVICE, child_env, facts, is_size, local_flake, luks_key, provisioning_module, shell_quote, validate_target_config


class ProfileTests(unittest.TestCase):
    def test_sizes(self):
        self.assertTrue(is_size("32G"))
        self.assertTrue(is_size("512M"))
        self.assertFalse(is_size("32"))
        self.assertFalse(is_size("32GB"))

    def test_layout_requires_stable_system_disk(self):
        profile = Profile("test", system_device=UNSET_DEVICE)
        self.assertIn("no system disk selected", profile.validate())
        profile.system_device = "/dev/nvme0n1"
        self.assertTrue(any("by-id" in error for error in profile.validate()))

    def test_new_profile_has_no_selected_system_disk(self):
        profile = Profile("test")
        self.assertEqual(profile.system_device, UNSET_DEVICE)
        self.assertIn("no system disk selected", profile.validate())

    def test_layout_renders_only_requested_optional_disks(self):
        profile = Profile("test", system_device="/dev/disk/by-id/nvme-test", system_encrypt=True)
        rendered = profile.to_nix()
        self.assertIn('system.device = "/dev/disk/by-id/nvme-test";', rendered)
        self.assertNotIn("home.device", rendered)
        self.assertNotIn("data.device", rendered)

    def test_shell_quote_handles_single_quotes(self):
        self.assertEqual(shell_quote("a'b"), "'a'\\''b'")

    def test_luks_key_exists_only_while_disko_runs(self):
        with tempfile.TemporaryDirectory() as directory, patch("installer.SCRATCH", Path(directory)):
            key = Path(directory) / "luks.key"
            with luks_key("secret"):
                self.assertEqual(key.read_text(), "secret")
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertFalse(key.exists())

    def test_local_flake_keeps_untracked_provisioning_files(self):
        self.assertEqual(local_flake("/mnt/home/sheath/nixos"), "path:/mnt/home/sheath/nixos")

    def test_bootstrap_keeps_working_tree_fixes(self):
        install_sh = Path(__file__).resolve().parent.parent / "install.sh"
        self.assertIn('run "path:${REPO}#installer"', install_sh.read_text())

    def test_target_config_accepts_generated_encrypted_layout(self):
        profile = Profile("test", system_device="/dev/disk/by-id/test", system_encrypt=True)
        value = {
            "diskEnabled": True,
            "placeholder": False,
            "root": {"device": "/dev/mapper/cryptroot", "fsType": "btrfs"},
            "boot": {"device": "/dev/disk/by-partlabel/disk-system-ESP", "fsType": "vfat"},
            "home": {"device": "/dev/mapper/cryptroot", "fsType": "btrfs"},
            "luks": {"cryptroot": {"device": "/dev/disk/by-partlabel/disk-system-root", "keyFile": None}},
        }
        with patch("installer.nix", return_value=json.dumps(value)):
            validate_target_config(Path("/target"), "test", profile)

    def test_target_config_rejects_placeholder_filesystems(self):
        profile = Profile("test", system_device="/dev/disk/by-id/test")
        value = {
            "diskEnabled": False,
            "placeholder": True,
            "root": {"device": "/dev/disk/by-label/nixos", "fsType": "ext4"},
            "boot": {"device": "/dev/disk/by-label/BOOT", "fsType": "vfat"},
            "home": {"device": "none", "fsType": "tmpfs"},
            "luks": {},
        }
        with patch("installer.nix", return_value=json.dumps(value)):
            with self.assertRaisesRegex(RuntimeError, "not bootable"):
                validate_target_config(Path("/target"), "test", profile)

    def test_root_child_environment_uses_root_home(self):
        with patch("installer.os.geteuid", return_value=0), patch("installer.pwd.getpwuid", return_value=SimpleNamespace(pw_dir="/root")), patch.dict("installer.os.environ", {"HOME": "/home/nixos", "XDG_CACHE_HOME": "/home/nixos/.cache"}, clear=True):
            environment = child_env()
        self.assertEqual(environment["HOME"], "/root")
        self.assertNotIn("XDG_CACHE_HOME", environment)

    def test_encryption_moves_together_and_clears_secret(self):
        board = Board(".", ["test"])
        board.profile = Profile("test", system_device="/dev/disk/by-id/nvme-test", home_device="/dev/disk/by-id/home")
        board.luks_passphrase = "secret"
        board.set_encryption(True)
        self.assertTrue(board.profile.system_encrypt)
        self.assertTrue(board.profile.home_encrypt)
        board.set_encryption(False)
        self.assertFalse(board.profile.system_encrypt)
        self.assertFalse(board.profile.home_encrypt)
        self.assertEqual(board.luks_passphrase, "")

    def test_slash_prefixed_checklist_labels_dispatch(self):
        board = Board(".", ["test"])
        board.profile = Profile("test", system_device="/dev/disk/by-id/nvme-test")
        board.check("/home disk")
        board.check("/data disk")
        self.assertTrue(board.status["/home disk"].ready)
        self.assertTrue(board.status["/data disk"].ready)

    def test_facts_expression_closes_its_nix_string(self):
        with patch("installer.nix", return_value="ageKeyFile=/persist/key\n") as nix_command:
            facts(".", "test")
        expression = nix_command.call_args.args[1][-1]
        self.assertTrue(expression.rstrip().endswith("''"))

    def test_provisioning_module_imports_local_facts_only_when_present(self):
        module = provisioning_module()
        self.assertIn("builtins.pathExists ./disk.nix", module)
        self.assertIn("builtins.pathExists ./hardware.nix", module)
        self.assertIn("lib.mkForce false", module)

    def test_install_command_disables_nixos_install_password_prompt(self):
        from installer import run_install

        self.assertIn("--no-root-passwd", inspect.getsource(run_install))

    def test_install_completion_is_versioned_for_local_provisioning(self):
        from installer import run_install

        self.assertIn('marked("install-local-provisioning")', inspect.getsource(run_install))

    def test_install_seeds_ssh_keys_before_nixos_activation(self):
        from installer import run_install

        source = inspect.getsource(run_install)
        self.assertIn('TARGET / "etc/ssh"', source)
        self.assertIn("ssh-keygen", source)

    def test_secret_phase_requires_host_keys_on_resume(self):
        from installer import run_install

        self.assertIn("all(path.is_file() for path in host_keys)", inspect.getsource(run_install))

    def test_completed_install_shows_completion_state(self):
        from installer import Tui

        tui = Tui(Board(".", ["test"]))
        tui.events.put(("done", "installed"))
        tui.pump()
        self.assertTrue(tui.completed)
        self.assertEqual(tui.current_phase, "complete")


if __name__ == "__main__":
    unittest.main()
