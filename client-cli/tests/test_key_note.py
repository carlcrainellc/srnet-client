import unittest
from srnet import cli


class KeyNote(unittest.TestCase):
    def test_new_key_note_is_current(self):
        n = cli.NEW_KEY_NOTE
        self.assertIn("gasless", n)
        self.assertIn("top up your SRNet balance from any wallet", n)
        self.assertIn("only needed for now to pay directly from this key", n)
        self.assertIn("Back up the keystore file and your passphrase", n)
        self.assertNotIn("with ETH for gas and USDC", n)


if __name__ == "__main__":
    unittest.main()
