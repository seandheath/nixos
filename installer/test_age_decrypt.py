"""Exercise passphrase decryption with the packaged age executable."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from installer import age_decrypt


class AgeDecryptTests(unittest.TestCase):
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
