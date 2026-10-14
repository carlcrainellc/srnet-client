import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLI_DIR = Path(__file__).resolve().parents[1]


class MailCLI(unittest.TestCase):
    def run_cli(self, home, *a):
        return subprocess.run([sys.executable, "-m", "srnet", "--home", home, "mail", *a],
                              cwd=CLI_DIR, capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def test_help_and_petname(self):
        with tempfile.TemporaryDirectory() as h:
            r = self.run_cli(h, "-h")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("srnet://mail", r.stdout)
            r = self.run_cli(h, "name", "srnet://room/abc?name=Bobs%20Room")
            self.assertEqual(json.loads(r.stdout)["name"], "Bobs Room")
            r = self.run_cli(h, "address")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("no mail hosts", r.stderr)
            self.assertTrue((Path(h) / "snapps" / "author.key").exists())
