"""Regressions for default selection, disk safety, settings and async validation."""
import copy
import json
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path
from unittest.mock import patch

from installer import Board, Facts, Profile, Status, Tui
from settings import Settings, locale_catalog, nix_string
from storage import Disk, Filesystem, inventory, storage_errors


class InstallerSafetyTests(unittest.TestCase):
    def test_defaults_do_not_choose_an_arbitrary_host(self):
        with patch('installer.saved_choices', return_value=None), patch('installer.socket.gethostname', return_value='nixos'):
            self.assertEqual(Board('.', ['first', 'second']).host, '')
            self.assertEqual(Board('.', ['only']).host, 'only')

    def test_host_defaults_select_one_blank_disk_and_saved_choices_win(self):
        defaults = {
            'disk': {'enable': True, 'system': {'device': None, 'encrypt': False},
                     'home': {'device': None, 'encrypt': False}, 'data': {'device': None, 'fsType': 'btrfs'},
                     'espSize': '1G', 'tmpfsSize': '6G', 'rootMode': 'subvol', 'swapSize': None},
            'persistentRoot': False, 'settings': asdict(Settings(hostname='test')),
            'users': ['sheath', 'root'], 'adminUser': 'sheath', 'family': False,
        }
        disk = Disk('sda', '100G', '', '', '/dev/disk/by-id/blank', 100 * 1024**3, True)
        with patch('installer.host_defaults', return_value=defaults), patch('installer.facts', return_value=Facts('/key', 'secrets.yaml', 'none', False, False)), \
             patch('installer.scan', return_value=([disk], [])), patch('installer.saved_choices', return_value=None) as saved:
            b = Board('.', ['test'])
            b.load_host()
            self.assertEqual(b.profile.system_device, disk.by_id)
            b.settings.hostname = 'saved-host'
            saved.return_value = {'version': 1, 'profile': asdict(b.profile), 'settings': asdict(b.settings)}
            defaults['settings']['hostname'] = 'profile-host'
            b.load_host()
            self.assertEqual(b.settings.hostname, 'saved-host')

    def test_successful_layout_check_writes_only_to_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo/'flake.nix').write_text('{}')
            b = Board(repo, ['test'], allow_writes=False)
            b.profile = Profile('test', '/dev/disk/by-id/test')
            b.status['settings'] = b.status['sizes'] = Status('ok', 'valid')
            try:
                with patch('installer.command', return_value='{}'), patch('installer.nix', return_value=''), \
                     patch('installer.validate_target_config'), patch('installer.facts', return_value=Facts('/key', 'secrets.yaml', 'none', False, False)):
                    self.assertEqual(b.check_layout().kind, 'ok')
                self.assertFalse((repo/'provisioning').exists())
                self.assertTrue((b.provisioning_dir/'settings.nix').is_file())
                self.assertEqual((repo/'flake.nix').read_text(), '{}')
            finally:
                b.cleanup()

    def test_only_blank_internal_disks_are_automatic(self):
        d = Disk('sda', '100G', '', '', '/dev/disk/by-id/a', 100 * 1024**3, True)
        self.assertTrue(d.automatic)
        for attr, value in [('external', True), ('readonly', True), ('mounts', {'/'}), ('blank', False), ('by_id', None)]:
            other = copy.deepcopy(d)
            setattr(other, attr, value)
            self.assertFalse(other.automatic, attr)

    def test_multidevice_filesystem_protects_every_member(self):
        nodes = [{'name': name, 'type': 'disk', 'size': 100 * 1024**3,
                  'children': [{'name': name + '1', 'type': 'part', 'fstype': 'btrfs',
                                'uuid': 'shared', 'mountpoints': ['/data'] if name == 'sda' else []}]}
                 for name in ('sda', 'sdb')]
        with patch('storage.by_id_for', side_effect=str):
            disks, filesystems = inventory({'blockdevices': nodes})
        self.assertEqual(filesystems[0].members, {'/dev/sda', '/dev/sdb'})
        self.assertEqual(disks[1].mounts, {'/data'})
        for d in disks:
            errors = storage_errors(disks, filesystems, d.path, None, '/dev/disk/by-uuid/shared', 'btrfs')
            self.assertTrue(any('preserved' in e for e in errors))
            self.assertTrue(any('in use' in e for e in errors))

    def test_aliases_cannot_select_one_disk_twice(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory)
            (p/'disk').touch()
            (p/'first').symlink_to(p/'disk')
            (p/'second').symlink_to(p/'disk')
            disk = Disk('fake', '100G', '', '', str(p/'first'), 100 * 1024**3)
            errors = storage_errors([disk], [], str(p/'first'), str(p/'second'), None, 'btrfs')
            self.assertIn('system and home refer to the same physical disk', errors)

    def test_mounts_are_only_allowed_for_matching_resume(self):
        disk = Disk('sda', '100G', '', '', '/dev/sda', 100 * 1024**3, mounts={'/mnt/nix'})
        self.assertTrue(storage_errors([disk], [], '/dev/sda', None, None, 'btrfs'))
        self.assertFalse(storage_errors([disk], [], '/dev/sda', None, None, 'btrfs', resume=True))
        disk.mounts.add('/run/live')
        self.assertTrue(storage_errors([disk], [], '/dev/sda', None, None, 'btrfs', resume=True))

    def test_settings_escape_nix_and_only_reference_passwords(self):
        settings = Settings(hostname='tower', username='alice', full_name='A "name" ${literal}',
                            user_password_mode='custom', root_password_mode='user')
        rendered = settings.to_nix()
        self.assertIn(r'\${literal}', rendered)
        self.assertIn(r'\"name\"', rendered)
        self.assertIn('/persist/secrets/login-password', rendered)
        self.assertNotIn('hashedPassword =', rendered)
        self.assertEqual(nix_string('a\nb'), '"a\\nb"')

    def test_locale_catalog_only_offers_supported_utf8_pairs(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory)/'SUPPORTED'
            catalog.write_text("en_US.UTF-8/UTF-8\naa_DJ/ISO-8859-1\naa_ER/UTF-8\n")
            with patch.dict('settings.os.environ', {'INSTALLER_LOCALES': str(catalog)}):
                self.assertEqual(locale_catalog(), ['aa_ER', 'en_US.UTF-8'])

    def test_settings_validate_names_locale_and_keyboard(self):
        with patch('settings.keyboard_catalog', return_value=({'pc104'}, {'us': {''}})), patch('settings.locale_catalog', return_value=['en_US.UTF-8']):
            settings = Settings(hostname='tower', username='alice')
            self.assertFalse(settings.validate())
            settings.username = 'root'
            settings.locale = 'not_a_locale'
            settings.keyboard_variant = 'unknown'
            settings.full_name = 'name\tfield'
            self.assertEqual(len(settings.validate()), 4)
            settings = Settings(hostname='tower', desktop='none', auto_login=True)
            self.assertIn('automatic graphical login requires a desktop', settings.validate())

    def test_stale_validation_cannot_replace_edits(self):
        tui = Tui(Board('.', ['test']))
        snapshot = copy.deepcopy(tui.board)
        snapshot.settings.hostname = 'stale'
        tui.board.settings.hostname = 'new'
        tui.revision = 1
        tui.events.put(('validated', (0, snapshot)))
        with patch.object(tui, 'start_validation') as start:
            tui.pump()
            start.assert_called_once()
        self.assertEqual(tui.board.settings.hostname, 'new')

    def test_current_validation_installs_snapshot(self):
        tui = Tui(Board('.', ['test']))
        snapshot = copy.deepcopy(tui.board)
        snapshot.settings.hostname = 'validated'
        tui.events.put(('validated', (0, snapshot)))
        tui.pump()
        self.assertIs(tui.board, snapshot)

    def test_resume_requires_all_mounts_and_same_layout(self):
        board = Board('.', ['test'])
        board.profile = Profile('test', '/dev/disk/by-id/test')
        saved = {'profile': asdict(board.profile), 'mount_uuids': {'/nix': 'uuid'}}
        with patch('installer.saved_choices', return_value=saved), patch('installer.partition_complete', return_value=True):
            self.assertFalse(board.resume_matches())
            saved['profile']['system_encrypt'] = True
            self.assertFalse(board.resume_matches())

    def test_failed_validation_never_writes_to_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            board = Board(directory, ['test'], allow_writes=False)
            board.profile = Profile('test')
            self.assertEqual(board.check_layout().kind, 'pending')
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
