"""Real-Chrome tests for the native Exits and Wallet tabs and Check my setup (playwright + Chrome; skipped otherwise).
The wallet backend is the real srnet.ui Backend behind the core's /api/wallet bridge; only network/chain calls are mocked.
Mainnet safety: Buy shows a 'final' sheet that needs the passphrase, and Cancel sends nothing."""
import os, sys, tempfile, threading, unittest
from pathlib import Path
from unittest import mock
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[1]))
sys.path[:0] = [str(HERE.parents[2] / "client-cli"), str(HERE.parents[2] / "client-cli" / "vendor")]
from test_room_ui import CHROME, sync_playwright  # noqa: E402
from typed import testbed as T  # noqa: E402
from typed.core import Core, serve as core_serve  # noqa: E402
from srnet import state, ui  # noqa: E402

SELLER = "x" * 52 + ".sesh"
ADDR = "0x" + "ab" * 20


def wait_text(pg, sel, ok, timeout=15):
    import time
    end = time.time() + timeout
    while time.time() < end:
        t = pg.locator(sel).text_content() or ""
        if ok(t):
            return t
        time.sleep(0.2)
    raise AssertionError(f"{sel} never matched: {t!r}")


@unittest.skipUnless(sync_playwright and CHROME, "playwright or Chrome not installed")
class WalletTabs(unittest.TestCase):
    def setUp(self):
        self.be = ui.Backend(state.State(Path(tempfile.mkdtemp())))
        self.calls = []
        self.be.board = lambda: {"seq": 7, "source": "test", "dropped": 0, "listings": [
            {"seller": SELLER, "region": "us-east", "price": "0.10", "age_s": 300}]}
        self.be.status = lambda pw=None: {"address": ADDR, "usdc_wallet": 12.5, "deposited": 3, "eth": 0.001,
                                          "seller": None, "connected": None, "auto_renew": False}

        def buy(*a):
            self.calls.append(("buy",) + a)
            return {"out": "bought"}
        self.be.buy = buy
        self.wsrv, url = ui.serve(self.be)
        threading.Thread(target=self.wsrv.serve_forever, daemon=True).start()
        base, tok = url.split("?k=", 1)
        self.env = T.start(mirror=False)
        self.core = Core(tempfile.mkdtemp(prefix="wtabs-"), T.client_config(self.env))
        self.core.wallet = (base.rstrip("/"), tok)
        self.srv = core_serve(self.core, 0)
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}/"

    def tearDown(self):
        self.srv.shutdown(); self.wsrv.shutdown(); T.stop(self.env)

    def test_exits_wallet_and_setup(self):
        with sync_playwright() as p:
            b = p.chromium.launch(executable_path=CHROME, args=["--no-sandbox"])
            pg = b.new_page()
            errs = []
            pg.on("pageerror", lambda e: errs.append(str(e)))
            pg.goto(self.base)
            pg.wait_for_selector("#home:not([hidden])", timeout=20000)  # opens on Home
            # Exits: board renders natively; Buy asks for the passphrase and says final; Cancel sends nothing
            pg.click("#ribbon button[data-b=exits]")
            pg.wait_for_selector("#x-board tbody tr", timeout=15000)
            self.assertIn("us-east", pg.inner_text("#x-board"))
            self.assertIn("signed board seq 7", pg.inner_text("#x-boardinfo"))
            self.assertEqual(pg.inner_text("#w-addr"), ADDR)
            pg.click("#x-board button:has-text('Buy 1 hour')")
            pg.wait_for_selector("#sheet:not([hidden])")
            self.assertIn("final", pg.inner_text("#sheet").lower())
            self.assertTrue(pg.is_visible("#sheet-pw"))
            pg.click("#sheet-buttons button:has-text('Cancel')")
            self.assertEqual(self.calls, [])
            # Buy with a passphrase reaches the backend with it
            pg.fill("#x-cs", "y" * 52 + ".sesh")
            pg.click("#x-board button:has-text('Buy 1 hour')")
            pg.fill("#sheet-pw", "pw123")
            pg.click("#sheet-buttons button:has-text('Buy (final)')")
            wait_text(pg, "#x-log", lambda t: "ok" in t)
            self.assertEqual(self.calls[0][1:], (SELLER, "y" * 52 + ".sesh", False, "pw123"))
            # Wallet: balances + top-up QR info with the USDC-only warning
            pg.click("#ribbon button[data-b=wallet]")
            self.assertTrue(pg.is_visible("#wallet"))
            self.assertIn("12.50", pg.inner_text("#w-usdc"))
            with mock.patch("srnet.keys.address_of", return_value=ADDR):
                pg.click("#w-showqr")
                wait_text(pg, "#w-warn", bool)
            self.assertIn("Send only USDC", pg.inner_text("#w-warn"))
            self.assertIn("uint256=10000000", pg.inner_text("#w-uri"))
            # relayer allow-list still enforced by the backend
            pg.fill("#w-relayer", "http://evil.example/")
            pg.click("#w-saverelayer")
            wait_text(pg, "#w-topupstate", bool)
            self.assertNotIn("saved", pg.inner_text("#w-topupstate"))
            # Check my setup
            pg.click("#ribbon button[data-b=home]")
            with mock.patch("srnet.preflight.run", return_value={"preflight": "OK", "when": "t", "host": "h", "checks": [
                    {"check": "dns", "status": "PASS", "detail": "ok", "fix": ""}]}), \
                 mock.patch("srnet.preflight.default_report_path", return_value=Path(tempfile.mkdtemp()) / "r.txt"):
                pg.click("#preflight-go")
                pg.wait_for_selector("#preflight-out:not([hidden])", timeout=20000)
            self.assertIn("PREFLIGHT=OK", pg.inner_text("#preflight-out"))
            self.assertIn("result: OK", pg.inner_text("#preflight-sum"))
            self.assertEqual(errs, [])
            b.close()


if __name__ == "__main__":
    unittest.main()
