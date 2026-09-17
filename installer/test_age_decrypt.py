"""Exercise passphrase decryption with the packaged age executable."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from installer import Board, Facts, age_decrypt


class AgeDecryptTests(unittest.TestCase):
    def test_key_bundle_matches_any_authorized_identity(self):
        keys = [subprocess.run(["age-keygen"], capture_output=True, check=True) for _ in range(3)]
        recipients = [key.stderr.decode().strip().removeprefix("Public key: ") for key in keys]
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "key").write_bytes(keys[0].stdout + keys[1].stdout)
            (repo / "secrets").mkdir()
            secrets = repo / "secrets/secrets.yaml"
            board = Board(repo, ["test"])
            board.facts = Facts("/key", "secrets.yaml", "none", False, False)
            with patch("installer.TARGET", repo), patch.object(board, "resume_matches", return_value=True):
                for recipient in recipients[:2]:
                    secrets.write_text(f"recipient: {recipient}\n")
                    self.assertTrue(board.check_age_key().ready)
                secrets.write_text(f"recipient: {recipients[2]}\n")
                self.assertFalse(board.check_age_key().ready)

    def test_passphrase_decryption_and_failure_without_terminal_prompts(self):
        password = "fixture ' $() ü password"
        plaintext = b"fixture secrets key\n"
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "encrypted ' key.age"
            destination = Path(directory) / "decrypted key"
            subprocess.run(
                ["age", "-e", "-j", "batchpass", "-o", str(source)],
                input=plaintext, capture_output=True, check=True, timeout=15,
                env=os.environ | {"AGE_PASSPHRASE": password, "AGE_PASSPHRASE_FD": "",
                                  "AGE_PASSPHRASE_WORK_FACTOR": "10"},
            )
            with self.assertRaisesRegex(RuntimeError, "incorrect passphrase") as error:
                age_decrypt(source, destination, "wrong fixture password")
            self.assertNotIn("Enter passphrase", str(error.exception))
            self.assertNotIn("wrong fixture password", str(error.exception))
            self.assertFalse(destination.exists())

            age_decrypt(source, destination, password)
            self.assertEqual(destination.read_bytes(), plaintext)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)

            with self.assertRaises(RuntimeError):
                age_decrypt(source, destination, "wrong fixture password")
            self.assertEqual(destination.read_bytes(), plaintext)


if __name__ == "__main__":
    unittest.main()
