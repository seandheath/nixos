"""Install-state regression using a temporary target and stubbed system commands."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from installer import Board, Facts, Profile, Status, keyboard_preview, luks_key, run_install
from settings import Settings


class InstallStateTests(unittest.TestCase):
    def test_secrets_stay_out_of_checkout_and_settings_changes_reinstall(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, target, stage = [root / n for n in ('repo', 'target', 'stage')]
            repo.mkdir()
            (repo/'flake.nix').write_text('{}')
            board = Board(repo, ['test'])
            board.profile = Profile('test', '/dev/disk/by-id/system')
            board.settings = Settings(hostname='tower', username='tester', user_password_mode='custom', root_password_mode='custom')
            board.facts = board.base_facts = Facts('/persist/secrets/age-key', 'secrets.yaml', 'persist', False, False)
            board.stage = stage
            board.status = {k: Status('ok', 'valid') for k in board.status}
            board.user_password, board.root_password = 'login-secret', 'root-secret'
            board.provisioning_dir.mkdir(parents=True)
            for name in ('default.nix', 'disk.nix', 'hardware.nix'):
                (board.provisioning_dir/name).write_text('{}')
            (board.provisioning_dir/'settings.nix').write_text(board.settings.to_nix())
            installs = []

            def stream(args, *unused):
                if args[0] == 'ssh-keygen':
                    Path(args[args.index('-f') + 1]).touch()
                if args[0] == 'nixos-install':
                    installs.append(args)
                    profile = target/'nix/var/nix/profiles/system'
                    profile.parent.mkdir(parents=True, exist_ok=True)
                    if not profile.is_symlink(): profile.symlink_to('/nix/store/test-system')

            def command(args, *unused, **kwargs):
                if args[0] == 'mkpasswd':
                    self.assertIn(kwargs['input_text'], ('login-secret', 'root-secret'))
                    return '$6$test-hash\n'
                return 'fixture-uuid\n'

            def decrypt(source, destination, password):
                destination.write_text('fixture-age-key')

            with patch('installer.TARGET', target), patch('installer.scan', return_value=([], [])), \
                 patch.object(board, 'check_cheap'), patch.object(board, 'resume_matches', return_value=False) as resume, \
                 patch('installer.partition_complete', return_value=False), patch('installer.stream', side_effect=stream), \
                 patch('installer.command', side_effect=command), patch('installer.age_decrypt', side_effect=decrypt), \
                 patch('installer.validate_target_config'):
                run_install(board, lambda _: None)
                self.assertEqual(len(installs), 1)
                dest = target/'home/tester/nixos'
                for path in dest.rglob('*.nix'):
                    self.assertNotIn('secret', path.read_text().replace('/persist/secrets/', ''))
                    self.assertNotIn('$6$', path.read_text())
                for name in ('login-password', 'root-password'):
                    path = target/'persist/secrets'/name
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(path.read_text(), '$6$test-hash\n')
                self.assertFalse((repo/'provisioning').exists())
                saved = json.loads((target/'persist/nixos-install/choices.json').read_text())
                self.assertNotIn('login-secret', json.dumps(saved))
                board.user_password = board.root_password = ''
                resume.return_value = True
                with patch('installer.saved_choices', return_value=saved):
                    run_install(board, lambda _: None)
                    self.assertEqual(len(installs), 1, 'identical completed settings should resume')
                    board.settings.hostname = 'changed'
                    (board.provisioning_dir/'settings.nix').write_text(board.settings.to_nix())
                    run_install(board, lambda _: None)
                    self.assertEqual(len(installs), 2, 'edited settings must reinstall')
                    self.assertIn('changed', (dest/'provisioning/test/settings.nix').read_text())

    def test_keyboard_restores_after_cancel_or_error(self):
        with patch('installer.os.ttyname', return_value='/dev/tty1'), patch('installer.command', side_effect=['original', 'preview', '', '']) as command:
            with self.assertRaisesRegex(RuntimeError, 'cancel'):
                with keyboard_preview(Settings()):
                    raise RuntimeError('cancel')
            self.assertEqual(command.call_args.kwargs['input_text'], 'original')

    def test_luks_key_refuses_existing_symlink(self):
        with tempfile.TemporaryDirectory() as directory, patch('installer.SCRATCH', Path(directory)):
            victim = Path(directory)/'victim'
            victim.write_text('unchanged')
            (Path(directory)/'luks.key').symlink_to(victim)
            with self.assertRaises(FileExistsError):
                with luks_key('password'):
                    self.fail('must not use a preexisting key')
            self.assertEqual(victim.read_text(), 'unchanged')


if __name__ == '__main__':
    unittest.main()
