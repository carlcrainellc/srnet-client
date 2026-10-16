#!/usr/bin/env python3
"""srnet: SNApps, exits and wallet for SRNet.

  srnet doctor             check Python packages, RPC, chain, wallet and balances
  srnet exits              exit marketplace (Beta / Untested): list sellers from the signed board
  srnet buy <seller>       prepay 1 hour (default; --hours N) from your SRNet balance
  srnet connect <seller>   MapExit full_tunnel; if the exit is not EXIT_CAPABLE: unmap and stop renewing
  srnet renew [--loop]     auto-renew hour by hour (default on): buys the next hour in the last 10 minutes
  srnet stop               stop auto-renew (the current paid hour still runs out; no refund)
  srnet status
  srnet disconnect         unmap, and stop auto-renew
  srnet topup --amount N   top up: QR / send USDC from any wallet, gasless deposit via your relayer
  srnet deliver            resend your last claim to the seller (buy does this automatically)
  srnet pay --vendor-id V --amount N  pay any SRNet seller from your SRNet balance
  srnet cashout --amount N withdraw unused SRNet balance to your wallet
  srnet vendor --shop-key K  seller: bind a vendor id for SRNet-balance payments
  srnet snapps [--config F] typed SNApps client (boards, rooms, wiki, shop, drop, pages)
  srnet ui                 the app: SNApps, Exits, Wallet / Top up (also plain `srnet`)

GASLESS: fund with USDC on Arbitrum One (QR or any wallet). Set a relayer once ("relayer" in
config.json or $SRNET_RELAYER); top-ups, payments, renewals and cash-outs then need no ETH.
EXITS ARE BETA / UNTESTED: they work but are not production-certified; keep amounts small.
PAYMENT IS FINAL: once a lease starts the seller may take that hour; there is no buyer
cancel and no refund. Buying one hour at a time keeps the most you can lose at about one hour's price.
Defaults: nftables kill switch (clearnet TCP and DNS), first-run visibility warning, hourly
auto-renew. Plain DNS is blocked. Turn on DNS-over-HTTPS in your browser, or names won't resolve.

  srnet key new|import     create the encrypted wallet keystore ($SRNET_HOME/keystore.json)

Settings come from flags, then $SRNET_HOME/config.json (keys: rpc, keystore, listings_path,
board_urls, board_pin, sesh_dns, spool, omq, relayer), then env (SRNET_RPC), then the Arbitrum One default (https://arb1.arbitrum.io/rpc). The wallet key comes from the keystore; the passphrase is
prompted or read from SRNET_KEYSTORE_PASSWORD. Plaintext --private-key / SRNET_PRIVATE_KEY
still work but print a warning. Arbitrum One uses real USDC: the contract is unaudited, keep
amounts small.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import warning, listings, killswitch, doh, rpc, chain, state, keys
from . import board as boardmod
from .backend import LiveBackend

# Put sibling packs on path
_ROOT = Path(__file__).resolve().parents[1]
_LEASE = _ROOT / "vendor"
if not _LEASE.is_dir():  # installed with pip: vendor/ ships inside the package
    _LEASE = Path(__file__).resolve().parent / "vendor"
_PACK = _LEASE
for p in (_LEASE, _PACK, _ROOT):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))


def _cfg(st: state.State) -> dict:
    cfg_path = st.root / "config.json"
    if not cfg_path.exists():
        return {}
    return json.loads(cfg_path.read_text())


def _save_cfg(st: state.State, cfg: dict) -> None:
    (st.root / "config.json").write_text(json.dumps(cfg, indent=2, sort_keys=True))


def load_listings(args, st: state.State, quiet: bool = False) -> list[dict]:
    """--listings FILE if given, else the signed board fetched over Session Router."""
    cfg = _cfg(st)
    lp = getattr(args, "listings", None) or cfg.get("listings_path")
    if lp:
        return listings.load_board(Path(lp))
    good, info = boardmod.fetch(boardmod.sources(cfg), boardmod.pin_of(cfg), st.root,
                                dns=cfg.get("sesh_dns"))
    if not quiet:
        src = "cached copy" if info["source"] == "cache" else info["source"]
        print(f"board seq {info['seq']} from {src}; {len(info['dropped'])} listing(s) dropped",
              file=sys.stderr)
    return good


def cmd_exits(args, st: state.State) -> int:
    try:
        board = load_listings(args, st)
    except boardmod.B.BoardError as e:
        print(f"board unavailable: {e}", file=sys.stderr)
        print("is session-router running? or pass --listings FILE", file=sys.stderr)
        return 1
    if args.listings:
        st.data["listings_path"] = str(args.listings)
        st.save()
    if not board:
        print("(no valid listings)")
        return 0
    print("Exit marketplace: Beta / Untested. Not production-certified; buy one hour at a time.", file=sys.stderr)
    print(boardmod.table(board, time.time()))
    return 0


def cmd_buy(args, st: state.State) -> int:
    warning.ensure_ack(st.root)
    cfg = _cfg(st)
    try:
        board = load_listings(args, st)
    except boardmod.B.BoardError as e:
        print(f"board unavailable: {e}", file=sys.stderr)
        return 1
    doc = listings.find_seller(board, args.seller)
    if not doc:
        print(f"seller not found (or bad sig dropped): {args.seller}", file=sys.stderr)
        return 1
    L = doc["listing"]
    cid = int(L["chainid"])
    chain.refuse_unsupported(cid)
    known = chain.DEPLOYMENTS.get(cid)
    if known and L["contract"].lower() != known.lower():
        print(f"refusing: listing points at {L['contract']}, not the SRNetBalance deployment on "
              f"{_chain_name(cid)} ({known})", file=sys.stderr)
        return 1
    if cid in chain.MAINNET_CHAINS:
        print("note: Arbitrum One, real USDC. The contract is unaudited; keep amounts small.", file=sys.stderr)
    # Build chain client
    if args.mock:
        ch = chain.MockChain(chainid=cid, contract=L["contract"])
        rate, hours = _rate_hours(args, L)
        amount = rate * hours
        ch.fund(amount * 2)
        hold_id = ch.start_lease(L["vendor_id"], rate, hours)
        user = ch.address()
    else:
        rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
        pk, _ = keys.resolve(args, cfg, st.root)
        if not rpc_url or not pk:
            print(_MISSING_CFG, file=sys.stderr)
            return 2
        ch = chain.ChainCfg(rpc=rpc_url, contract=L["contract"], private_key=pk, relayer=chain.relayer_url(cfg))
        if ch.chainid() != cid:
            print(f"wrong chain: your RPC is on {_chain_name(ch.chainid())} but this seller's listing is on "
                  f"{_chain_name(cid)}; use an RPC for {_chain_name(cid)}", file=sys.stderr)
            return 1
        rate, hours = _rate_hours(args, L)
        amount = rate * hours
        if args.fund:
            # Advanced: direct deposit from this key (needs ETH for gas). Normal path: srnet topup.
            print(
                "NOTE: --fund deposits directly from this key and needs ETH for gas (use srnet topup for "
                "the gas-free path). The deposit takes up to 3% as a non-refundable fee; "
                "cash-out later returns only unused available balance, not that fee.",
                file=sys.stderr,
            )
            # Enough for this lease plus one renewal after the deposit fee.
            bps = ch.fee_bps()
            ch.fund(-(-amount * 2 * 10_000 // (10_000 - bps)))
        from . import payments
        hold_id = payments.pay(ch, payments.Payment("exit", L["vendor_id"], rate, item="exit time",
                                                    seller=L["seller"], hours=hours))["lease_id"]
        user = ch.address()
    # Sign + drop claim for seller watcher
    from watcher import claim_message
    msg = claim_message(L["contract"], cid, hold_id, args.client_sesh)
    sig = ch.sign_claim(msg)
    claim = {"v": 1, "hold_id": hold_id, "client_sesh": args.client_sesh, "sig": sig}
    spool = Path(args.spool or cfg.get("spool") or (st.root / "spool"))
    spool.mkdir(parents=True, exist_ok=True)
    claim_path = spool / f"hold-{hold_id}.json"
    claim_path.write_text(json.dumps(claim, indent=2))
    delivery = None
    if not args.no_deliver and not args.mock:
        from . import deliver as D
        delivery = D.deliver(claim, L, dns=cfg.get("sesh_dns"), wait_admit=60,
                             attempts=6)
        print(f"claim delivery to seller: {delivery['status']}"
              + (f" ({delivery['reason']})" if delivery.get("reason") else ""), file=sys.stderr)
    st.data["pending_buy"] = {
        "seller": args.seller, "hold_id": hold_id, "contract": L["contract"].lower(),
        "chainid": cid, "vendor_id": L["vendor_id"], "amount": amount, "user": user,
        "rate_per_hour": rate, "hours": hours,
        "claim_path": str(claim_path), "delivery": delivery,
        "listing": {k: L.get(k) for k in ("seller", "claim_port")},
    }
    st.data["lease"] = {"seller": args.seller, "contract": L["contract"].lower(), "chainid": cid,
                        "current": hold_id, "renewed_from": [], "auto_renew": not args.no_auto_renew,
                        "client_sesh": args.client_sesh, "spool": str(spool), "rate_per_hour": rate}
    st.save()
    print(json.dumps({"ok": True, "hold_id": hold_id, "lease_id": hold_id, "rate_per_hour": rate, "hours": hours,
                      "amount": amount, "claim": str(claim_path), "seller": args.seller,
                      "final": True, "auto_renew": not args.no_auto_renew, "delivery": delivery}))
    return 0


def cmd_deliver(args, st: state.State) -> int:
    """Retry delivering the last claim to the seller (safe to repeat; the seller deduplicates)."""
    from . import deliver as D
    pb = st.data.get("pending_buy") or {}
    if not pb.get("claim_path") or not Path(pb["claim_path"]).exists():
        print("no claim to deliver; run srnet buy first", file=sys.stderr)
        return 1
    claim = json.loads(Path(pb["claim_path"]).read_text())
    r = D.deliver(claim, pb.get("listing") or {"seller": pb["seller"]}, dns=_cfg(st).get("sesh_dns"))
    pb["delivery"] = r
    st.save()
    print(json.dumps(r))
    return 0 if r["delivered"] and r["status"] in ("queued", "admitted") else 1


_MISSING_CFG = ("need a wallet: create a "
                "keystore with `srnet key new` or `srnet key import`. Run `srnet doctor` to check.")


def cmd_key(args, st: state.State) -> int:
    path = Path(args.keystore or _cfg(st).get("keystore") or keys.default_path(st.root))
    if args.key_cmd == "show":
        a = keys.address_of(path)
        if not a:
            print(f"no keystore at {path}", file=sys.stderr)
            return 1
        print(f"{a}  {path}")
        return 0
    if args.key_cmd == "import":
        import getpass
        pk = os.environ.get("SRNET_PRIVATE_KEY") if args.from_env else getpass.getpass("private key (0x...): ")
        if not pk:
            print("no private key given", file=sys.stderr)
            return 2
        try:
            from eth_account import Account
            Account.from_key(pk)
        except Exception:
            print("that is not a valid 32-byte hex private key", file=sys.stderr)
            return 2
        addr = keys.write(path, pk, keys._password(confirm=True))
    else:
        addr = keys.new(path, keys._password(confirm=True))
    print(f"{addr}  saved to {path}")
    if args.key_cmd == "new":
        print(NEW_KEY_NOTE)
    return 0


NEW_KEY_NOTE = (
    "Next: open `srnet ui`, go to Wallet / Top up, set your relayer once, then scan the QR or send\n"
    "USDC on Arbitrum One from any wallet to this address. Deposits and payments go through the\n"
    "relayer, so you never need ETH.\n"
    "Back up the keystore file and your passphrase: there is no recovery.")


def _chain_name(cid: int) -> str:
    return f"{chain.CHAINS.get(cid, 'chain')} ({cid})"


def cmd_doctor(args, st: state.State) -> int:
    """Setup preflight (Windows, router, DNS, demo, clock...) then what buy/connect need.
    Exit 0 if nothing failed. --setup-only skips the wallet/chain part."""
    from . import preflight
    rep = preflight.run(skip=tuple(args.skip or ()))
    print(preflight.text(rep), end="")
    try:
        path = preflight.write_report(rep, args.report, st.root)
        print(f"report: {path}  (send this file if you need help)", flush=True)
    except (OSError, RuntimeError) as e:
        print(f"report not written: {e}", flush=True)
    if args.setup_only:
        return 1 if rep["preflight"] == "FAIL" else 0
    cfg = _cfg(st)
    bad = 0

    def line(ok, what, detail=""):
        nonlocal bad
        tag = {True: "ok  ", False: "FAIL", None: "warn"}[ok]
        bad += ok is False
        print(f"[{tag}] {what}{': ' + detail if detail else ''}")

    line(sys.version_info >= (3, 10), "python", sys.version.split()[0])
    for mod, pkg in (("cryptography", "cryptography"), ("zmq", "pyzmq"), ("eth_account", "eth-account"),
                     ("eth_abi", "eth-abi")):
        try:
            __import__(mod)
            line(True, pkg)
        except ImportError:
            line(False, pkg, "not installed; run: pip install .")
    for tool in ("nft", "ip"):
        line(True if shutil.which(tool) else None, tool,
             "" if shutil.which(tool) else "not found (needed for the kill switch / connect)")
    lp = args.listings or cfg.get("listings_path") or st.data.get("listings_path")
    board = []
    if lp and Path(lp).exists():
        board = listings.load_board(Path(lp))
        line(True if board else None, "listings", f"{len(board)} valid in {lp}")
    else:
        line(None, "listings", "from the board (srnet exits)")
    rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
    try:
        pk, ksrc = keys.resolve(args, cfg, st.root, warn=False)
    except keys.KeyError_ as e:
        pk, ksrc = None, f"keystore locked: {e}"
    line(bool(pk) or False, "key source", ksrc)
    if not rpc_url:
        line(False, "rpc", "not set (--rpc, SRNET_RPC or config.json)")
    if not rpc_url or not pk:
        return 1
    contract = args.contract or (board[0]["listing"]["contract"] if board else None)
    want = int(board[0]["listing"]["chainid"]) if board else None
    try:
        ch = chain.ChainCfg(rpc=rpc_url, contract=contract or chain.DEFAULT_CONTRACT, private_key=pk, relayer=chain.relayer_url(cfg))
        line(True, "wallet", ch.address())
        try:
            cid = ch.chainid()
        except SystemExit as e:
            line(False, "chain", str(e))
            return 1
        line(want in (None, cid), "chain", _chain_name(cid) + ("" if want in (None, cid) else
             f"; listings are on {_chain_name(want)}"))
        rel = chain.relayer_url(cfg)
        line(True if rel else None, "relayer",
             rel or "not set; set it once (Wallet tab or \"relayer\" in config.json) for gas-free payments")
        if not contract:
            line(None, "contract", "unknown until a listing is loaded (or pass --contract)")
        else:
            line(True, "contract", f"{contract}, USDC {ch.usdc()}")
            usdc, allow, avail = ch.usdc_balance(), ch.allowance(), ch.available()
            line(usdc > 0 or avail > 0 or None, "USDC in wallet", f"{usdc / 1e6:.2f}")
            line(True, "SRNet balance", f"{avail / 1e6:.2f}" + ("" if avail else " (top up: srnet topup or the Wallet tab)"))
    except chain.ChainError as e:
        line(False, "chain", str(e))
    print("all good" if not bad else f"{bad} problem(s) above")
    return 1 if bad else 0


def _rate_hours(args, L: dict) -> tuple[int, int]:
    """Hourly pricing: rate from the signed listing (price_per_hour_usdc), whole hours >= 1."""
    from decimal import Decimal
    price = L.get("price_per_hour_usdc", L.get("price_usdc", "1"))
    rate = int(Decimal(str(price)) * 1_000_000)
    hours = 1 if args.hours is None else int(args.hours)
    if hours < 1 or rate < 1:
        raise SystemExit("need whole hours >= 1 and a positive listed price per hour")
    max_h = L.get("max_hours")
    if max_h and hours > int(max_h):
        raise SystemExit(f"seller lists at most {max_h} hours")
    if rate * hours > 20_000_000:
        raise SystemExit("lease over $20 cap: pick fewer hours")
    return rate, hours


def _drop_claim(ch, contract: str, cid: int, lease_id: int, client_sesh: str, spool: Path) -> Path:
    from watcher import claim_message
    sig = ch.sign_claim(claim_message(contract, cid, lease_id, client_sesh))
    spool.mkdir(parents=True, exist_ok=True)
    p = spool / f"hold-{lease_id}.json"
    p.write_text(json.dumps({"v": 1, "hold_id": lease_id, "client_sesh": client_sesh, "sig": sig}, indent=2))
    return p


def renew_once(ch, st: state.State, window: int = chain.RENEW_WINDOW) -> dict:
    """One auto-renew step: if the current lease is in its last `window` seconds (or ended), buy 1 more
    hour from the same seller at the same rate, then drop the claim for the new lease id."""
    L = st.data.get("lease") or {}
    if not L or not L.get("auto_renew"):
        return {"ok": True, "renewed": False, "reason": "auto_renew_off"}
    cur = int(L["current"])
    newest = chain.newest_lease(ch, cur)
    if newest != cur:  # renewed on chain but not recorded here; catch up before deciding
        L["renewed_from"].append(cur)
        L["current"] = cur = newest
        st.data["lease"] = L
        st.save()
        _drop_claim(ch, L["contract"], int(L["chainid"]), cur, L["client_sesh"], Path(L["spool"]))
    due, why = chain.renew_due(ch, cur, window)
    if not due:
        return {"ok": True, "renewed": False, "reason": why, "lease_id": cur}
    new_id = ch.renew(cur, 1)
    L["renewed_from"].append(cur)
    L["current"] = new_id
    st.data["lease"] = L
    st.save()  # persist before anything else can fail, so the next step renews new_id, not cur
    claim = _drop_claim(ch, L["contract"], int(L["chainid"]), new_id, L["client_sesh"], Path(L["spool"]))
    return {"ok": True, "renewed": True, "lease_id": new_id, "prev": cur, "claim": str(claim)}


def _chain_for(args, st: state.State, L: dict):
    if getattr(args, "mock", False):
        raise SystemExit("renew --mock is driven by unit tests (MockChain)")
    cfg = _cfg(st)
    rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
    pk, _ = keys.resolve(args, cfg, st.root)
    if not rpc_url or not pk:
        raise SystemExit(_MISSING_CFG)
    ch = chain.ChainCfg(rpc=rpc_url, contract=L["contract"], private_key=pk, relayer=chain.relayer_url(cfg))
    ch.chainid()  # refuses unsupported chains
    return ch


def cmd_renew(args, st: state.State) -> int:
    """Hourly auto-renew. Without --loop: one step (for cron/systemd timers). With --loop: keep going until
    `srnet stop`/`disconnect` turns auto-renew off or the seller stops the lease."""
    L = st.data.get("lease")
    if not L:
        print("no lease; run srnet buy first", file=sys.stderr)
        return 1
    ch = _chain_for(args, st, L)
    while True:
        try:
            r = renew_once(ch, st, int(args.window))
        except Exception as e:  # e.g. insufficient balance, paused: stop renewing, never retry blindly
            r = {"ok": False, "renewed": False, "reason": f"renew_failed:{e}"}
        print(json.dumps(r), flush=True)
        if not args.loop or not r["ok"] or r.get("reason") in ("auto_renew_off", "seller_stopped"):
            return 0 if r["ok"] else 1
        time.sleep(int(args.interval))
        st.data = state.State(st.root).data  # pick up `srnet stop` from another process


def cmd_stop(args, st: state.State) -> int:
    """Stop auto-renew. The hour already paid is final and runs out; nothing is refunded."""
    L = st.data.get("lease") or {}
    if L:
        L["auto_renew"] = False
        st.data["lease"] = L
        st.save()
    print(json.dumps({"ok": True, "auto_renew": False, "lease_id": L.get("current")}))
    return 0


def cmd_connect(args, st: state.State) -> int:
    warning.ensure_ack(st.root)
    cfg = _cfg(st)
    pending = st.data.get("pending_buy")
    if not pending or pending.get("seller") != args.seller:
        print("no pending buy for seller; run srnet buy first", file=sys.stderr)
        return 1

    # Kill switch + resolver hint
    ks = killswitch.KillSwitch(tun=cfg.get("tun", "sr-tun"), overlay_udp_port=int(cfg.get("overlay_udp_port", 1090)))
    wan = args.wan_if or cfg.get("wan_if") or _guess_wan()
    if not args.no_killswitch:
        try:
            ks.arm(wan, bootstrap_ips=cfg.get("bootstrap_ips") or [])
            print(f"kill switch armed on {wan} (tun={ks.tun})")
        except Exception as e:
            print(f"kill switch arm failed: {e}", file=sys.stderr)
            if not args.allow_no_ks:
                return 1
    resolv = Path(args.resolv or cfg.get("resolv") or (st.root / "resolv.conf"))
    doh.write_resolv(resolv)

    endpoint = args.rpc_endpoint or cfg.get("omq") or "tcp://127.0.0.1:1195"
    r = rpc.Rpc(endpoint)
    # Chain for release (payment is final; release = unmap + stop renewing, no chain call)
    if args.mock:
        ch = chain.MockChain(chainid=pending["chainid"], contract=pending["contract"])
        # recreate hold bookkeeping
        ch.holds[pending["hold_id"]] = {"vendor_id": pending.get("vendor_id"), "amount": pending["amount"],
                                         "active": True, "wallet": "0x" + "aa" * 20}
        ch.next_id = pending["hold_id"] + 1
    else:
        pk, _ = keys.resolve(args, cfg, st.root)
        rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
        if not rpc_url or not pk:
            print(_MISSING_CFG, file=sys.stderr)
            return 2
        ch = chain.ChainCfg(rpc=rpc_url, contract=pending["contract"], private_key=pk, relayer=chain.relayer_url(cfg))
        chain.refuse_unsupported(ch.chainid())

    spool = Path(args.spool or cfg.get("spool") or (st.root / "spool"))
    b = LiveBackend(r, ch, st, args.client_sesh, spool,
                    wait_admission=(lambda s, t: _wait_file_admission(args.admission_flag, t)) if args.admission_flag else None)
    from lease_flow import connect as lease_connect
    result = lease_connect(b, args.seller, capable_timeout_s=float(args.timeout))
    if result.ok:
        st.data["connected"] = {"seller": args.seller, "hold_id": result.hold_id, "at": int(time.time()),
                                "killswitch": ks.status(), "resolv": str(resolv)}
        st.save()
        print(json.dumps({"ok": True, "hold_id": result.hold_id, "steps": result.steps}))
        return 0
    # failure: kill switch stays armed (fail closed) unless asked to disarm; never renew a failed exit
    if st.data.get("lease"):
        st.data["lease"]["auto_renew"] = False
        st.save()
    print(json.dumps({"ok": False, "reason": result.reason, "steps": result.steps, "hold_id": result.hold_id}))
    return 1


def _wait_file_admission(flag: str, timeout: float) -> bool:
    p = Path(flag)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if p.exists() and p.read_text().strip() == "ok":
            return True
        time.sleep(1)
    return False


def _guess_wan() -> str:
    try:
        out = subprocess.check_output(["ip", "-o", "route", "get", "1.1.1.1"], text=True)
        parts = out.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    except Exception:
        pass
    return "eth0"


def cmd_status(args, st: state.State) -> int:
    cfg = _cfg(st)
    endpoint = args.rpc_endpoint or cfg.get("omq") or "tcp://127.0.0.1:1195"
    ks = killswitch.KillSwitch(tun=cfg.get("tun", "sr-tun"))
    info = {
        "pending_buy": st.data.get("pending_buy"),
        "connected": st.data.get("connected"),
        "killswitch": ks.status(),
        "visibility_ack": (st.root / "visibility.ack").exists(),
    }
    try:
        info["list_exits"] = rpc.Rpc(endpoint).list_exits()
    except Exception as e:
        info["list_exits_error"] = str(e)
    print(json.dumps(info, indent=2))
    return 0


def cmd_disconnect(args, st: state.State) -> int:
    cfg = _cfg(st)
    conn = st.data.get("connected") or {}
    seller = args.seller or conn.get("seller")
    endpoint = args.rpc_endpoint or cfg.get("omq") or "tcp://127.0.0.1:1195"
    if seller:
        try:
            rpc.Rpc(endpoint).unmap_exit(seller)
        except Exception as e:
            print(f"unmap: {e}", file=sys.stderr)
    ks = killswitch.KillSwitch(tun=cfg.get("tun", "sr-tun"))
    if not args.keep_killswitch:
        ks.disarm()
        print("kill switch disarmed")
    st.data["connected"] = None
    if st.data.get("lease"):
        st.data["lease"]["auto_renew"] = False
    st.save()
    print(json.dumps({"ok": True, "unmapped": seller, "auto_renew": False}))
    return 0


def cmd_topup(args, st: state.State) -> int:
    """Phone-wallet top-up: show QR of our own wallet, wait for USDC, sign permit + intent, relay."""
    from . import gasless
    cfg = _cfg(st)
    rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
    pk, _ = keys.resolve(args, cfg, st.root)
    contract = args.contract or cfg.get("contract") or chain.DEFAULT_CONTRACT
    if not pk:
        print(_MISSING_CFG, file=sys.stderr)
        return 2
    ch = chain.ChainCfg(rpc=rpc_url, contract=contract, private_key=pk, relayer=chain.relayer_url(cfg))
    cid = ch.chainid()
    usdc = ch.usdc()
    amount = int(round(args.amount * chain.USDC))
    print(gasless.topup_screen(ch.address(), cid, usdc, args.relay_fee, amount))
    bal = gasless.wait_for_usdc(ch.usdc_balance, amount, timeout=args.timeout)
    if args.all:
        amount = bal
    pnonce, name, version = ch.permit_info()
    req = gasless.sign_topup(ch._acct, chainid=cid, contract=contract, usdc=usdc, amount=amount,
                             permit_nonce=pnonce, relay_fee=args.relay_fee, usdc_name=name, usdc_version=version)
    relayer = args.relayer or cfg.get("relayer") or os.environ.get("SRNET_RELAYER")
    if not relayer:
        print(json.dumps(req, indent=2))
        print("no relayer set: set it once (Wallet tab, \"relayer\" in config.json or --relayer) and run "
              "srnet topup again; or hand the signed JSON above to any relayer (POST /fund)", file=sys.stderr)
        return 0
    out = gasless.submit(relayer, req)
    print(json.dumps({**out, "available": ch.available()}))
    return 0


def cmd_pay(args, st: state.State) -> int:
    """Pay any SRNet seller from your SRNet balance (store items, paid files, rooms)."""
    from . import payments
    cfg = _cfg(st)
    p = payments.Payment(args.purpose, args.vendor_id, payments.usdc(args.amount), item=args.item or "")
    try:
        lines = payments.describe(p)
    except payments.PaymentError as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    if not args.yes and input("Pay now? [y/N] ").strip().lower() != "y":
        print("cancelled", file=sys.stderr)
        return 1
    rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
    pk, _ = keys.resolve(args, cfg, st.root)
    if not pk:
        print(_MISSING_CFG, file=sys.stderr)
        return 2
    ch = chain.ChainCfg(rpc=rpc_url, contract=args.contract or cfg.get("contract") or chain.DEFAULT_CONTRACT,
                        private_key=pk, relayer=chain.relayer_url(cfg))
    print(json.dumps(payments.pay(ch, p)))
    return 0


def cmd_cashout(args, st: state.State) -> int:
    """Withdraw unused SRNet balance to your wallet (or --to). Gas-free when a relayer is set."""
    from . import payments
    cfg = _cfg(st)
    try:
        amount = payments.usdc(args.amount)
    except payments.PaymentError as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
    pk, _ = keys.resolve(args, cfg, st.root)
    if not pk:
        print(_MISSING_CFG, file=sys.stderr)
        return 2
    ch = chain.ChainCfg(rpc=rpc_url, contract=args.contract or cfg.get("contract") or chain.DEFAULT_CONTRACT,
                        private_key=pk, relayer=chain.relayer_url(cfg))
    to = args.to or ch.address()
    fee = f" plus a {ch.relay_fee / chain.USDC:.2f} USDC relay fee" if ch.relayer else ""
    print(f"cash out {amount / chain.USDC:.2f} USDC{fee} from your SRNet balance to {to}")
    if not args.yes and input("Continue? [y/N] ").strip().lower() != "y":
        print("cancelled", file=sys.stderr)
        return 1
    ch.cash_out(amount, to)
    print(json.dumps({"ok": True, "amount": amount, "to": to, "available": ch.available()}))
    return 0


def cmd_vendor(args, st: state.State) -> int:
    """Seller: bind a vendor id to your wallet (once) so buyers can pay you from SRNet balance."""
    from . import payments
    cfg = _cfg(st)
    rpc_url = args.rpc or cfg.get("rpc") or os.environ.get("SRNET_RPC") or chain.DEFAULT_RPC
    pk, _ = keys.resolve(args, cfg, st.root)
    if not pk:
        print(_MISSING_CFG, file=sys.stderr)
        return 2
    ch = chain.ChainCfg(rpc=rpc_url, contract=args.contract or cfg.get("contract") or chain.DEFAULT_CONTRACT,
                        private_key=pk)
    salt = payments.shop_salt(args.shop_key) if args.shop_key else (args.salt or "0x" + os.urandom(32).hex())
    vid = payments.vendor_id_for(ch.address(), salt)
    print(json.dumps({"vendor_id": vid, "salt": salt, "wallet": ch.address()}))
    if args.dry_run:
        return 0
    if ch.chainid() in chain.MAINNET_CHAINS and not args.yes:
        if input("This sends a transaction on Arbitrum One. Continue? [y/N] ").strip().lower() != "y":
            return 1
    ch._send("configureVendor(bytes32,bytes32)", vid, salt)
    print("vendor configured; put this vendor_id in your listings", file=sys.stderr)
    return 0


def cmd_snapps(args, st: state.State) -> int:
    """Start the typed-SNApp client (signed records, sandboxed templates, no-script HTML viewer)."""
    root = Path(os.environ.get("SRNET_SNAPPS_DIR") or Path(__file__).resolve().parents[2] / "snapps")
    if not (root / "typed" / "core.py").exists():
        print(f"typed SNApps not found at {root}; set SRNET_SNAPPS_DIR", file=sys.stderr)
        return 2
    data = args.data or str(st.root / "snapps")
    # shipped defaults (lobby + directory pre-joined, default mail host), then the user's config on top
    user_cfg = Path(args.config) if args.config else st.root / "client.json"
    cmd = [sys.executable, "-m", "typed.core", "--data", data, "--port", str(args.port)]
    if args.config or user_cfg.exists():
        if not user_cfg.exists():
            print(f"config not found: {user_cfg}", file=sys.stderr)
            return 2
        cmd += ["--config", str(user_cfg.resolve())]
    return _run_child(cmd, str(root))


def _run_child(cmd, cwd) -> int:
    """Run the core; SIGTERM / Ctrl-C to `srnet ui` must not orphan it (it would keep the port)."""
    child = subprocess.Popen(cmd, cwd=cwd)
    if os.name != "nt":
        import signal
        signal.signal(signal.SIGTERM, lambda *a: (child.terminate(), sys.exit(143)))
    try:
        return child.wait()
    except KeyboardInterrupt:
        child.terminate()
        raise
    finally:
        if child.poll() is None:
            child.terminate()


def cmd_ui(args, st: state.State) -> int:
    """The SRNet app: SNApps shell (opens on Home) with native Exits and Wallet tabs.
    The wallet backend (srnet.ui) runs on a token-protected loopback port inside this process;
    the core bridges the shell to it. `srnet snapps` is an alias. If a client already answers
    on --port, just open it."""
    if getattr(args, "legacy_page", False):  # hidden: the retired standalone wallet page
        from . import ui
        return ui.run(st, rpc_url=args.rpc, open_browser=not args.no_browser, legacy=True)
    import socket
    import threading
    import time
    import webbrowser
    home = f"http://127.0.0.1:{args.port}/"

    def up(port=None) -> bool:
        try:
            socket.create_connection(("127.0.0.1", port or args.port), timeout=1).close()
            return True
        except OSError:
            return False
    # one app per home: a second core on the same data dir would block on its database
    pf = st.root / "ui.port"
    try:
        prev = int(pf.read_text().strip())
    except (OSError, ValueError):
        prev = None
    if prev and prev != args.port and up(prev):
        args.port, home = prev, f"http://127.0.0.1:{prev}/"
    if up():
        print(f"srnet ui: {home} (already running)", flush=True)
        if not args.no_browser:
            webbrowser.open(home)
        return 0
    from . import ui
    os.environ["SRNET_WALLET_API"] = ui.start_background(st, rpc_url=args.rpc)
    if not args.no_browser:
        def _open():
            for _ in range(240):
                if up():
                    webbrowser.open(home)
                    return
                time.sleep(0.5)
        threading.Thread(target=_open, daemon=True).start()
    print(f"srnet ui: {home}\n(local only; Ctrl-C to stop)", flush=True)
    st.root.mkdir(parents=True, exist_ok=True)
    pf.write_text(str(args.port))
    return cmd_snapps(args, st)


def cmd_open(args, st: state.State) -> int:
    """srnet:// link handler: validate the link, then open the running client's join sheet.
    Nothing is joined until you click Join there."""
    root = Path(os.environ.get("SRNET_SNAPPS_DIR") or Path(__file__).resolve().parents[2] / "snapps")
    sys.path.insert(0, str(root))
    from typed import joins
    try:
        joins.parse(args.link)
    except joins.LinkError as e:
        print(f"not a valid SRNet link: {e}", file=sys.stderr)
        return 2
    from urllib.parse import quote
    url = f"http://127.0.0.1:{args.port}/?join=" + quote(args.link.strip(), safe="")
    print(url)
    if not args.print_only:
        import webbrowser
        webbrowser.open(url)
    return 0
def cmd_mail(args, st: state.State) -> int:
    """Sealed SRNet mail (typed.mailcli), using the same identity as `srnet snapps`."""
    root = Path(os.environ.get("SRNET_SNAPPS_DIR") or Path(__file__).resolve().parents[2] / "snapps")
    if not (root / "typed" / "mailcli.py").exists():
        print(f"typed SNApps not found at {root}; set SRNET_SNAPPS_DIR", file=sys.stderr)
        return 2
    cmd = [sys.executable, "-m", "typed.mailcli", "--data", str(st.root / "snapps"), *args.rest]
    return subprocess.call(cmd, cwd=str(root))


def main(argv=None) -> int:
    # Ensure lease_flow importable
    if str(_LEASE) not in sys.path:
        sys.path.insert(0, str(_LEASE))

    ap = argparse.ArgumentParser(prog="srnet", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--home", help="state dir (default ~/.srnet or $SRNET_HOME)")
    ap.add_argument("--keystore", help="wallet keystore file (default $SRNET_HOME/keystore.json)")
    sub = ap.add_subparsers(dest="cmd", metavar="COMMAND")
    ap.set_defaults(port=48920, no_browser=False, rpc=None, config=None, data=None, legacy_page=False)

    dr = sub.add_parser("doctor", help="check my setup (router, DNS, demo...) then packages, RPC, chain, wallet")
    dr.add_argument("--setup-only", action="store_true", help="only the setup preflight")
    dr.add_argument("--report", help="report file (default %%LOCALAPPDATA%%\\SRNet\\preflight-report.txt)")
    dr.add_argument("--skip", action="append", help="skip a check by name (repeatable), e.g. --skip demo")
    dr.add_argument("--listings", help="listings file; its contract and chain are checked")
    dr.add_argument("--contract", help="contract address to check when no listings are loaded")
    dr.add_argument("--rpc", help="JSON-RPC URL (default $SRNET_RPC, else Arbitrum One public RPC)")
    dr.add_argument("--private-key", help="plaintext wallet key (discouraged; use srnet key import)")

    k = sub.add_parser("key", help="create, import or show the encrypted wallet keystore")
    ksub = k.add_subparsers(dest="key_cmd", required=True, metavar="ACTION")
    ksub.add_parser("new", help="generate a new wallet and save it encrypted")
    ki = ksub.add_parser("import", help="encrypt an existing private key (prompted, not echoed)")
    ki.add_argument("--from-env", action="store_true", help="read the key from SRNET_PRIVATE_KEY instead")
    ksub.add_parser("show", help="print the keystore address")

    e = sub.add_parser("exits", help="exit marketplace (Beta / Untested): list sellers from the signed board")
    e.add_argument("--listings", help="offline: read listings.json / .jsonl instead of the board")

    b = sub.add_parser("buy", help="exits (Beta / Untested): prepay hour(s) from your SRNet balance; FINAL, no refund")
    b.add_argument("seller")
    b.add_argument("--listings", help="offline: listings file instead of the board")
    b.add_argument("--no-deliver", action="store_true", help="only write the claim to the local spool")
    b.add_argument("--client-sesh", required=True, help="your own .sesh address (goes in the claim)")
    b.add_argument("--rpc", help="JSON-RPC URL (default $SRNET_RPC, else Arbitrum One public RPC)")
    b.add_argument("--private-key", help="plaintext wallet key (discouraged; use srnet key import)")
    b.add_argument("--hours", type=int, default=1,
                   help="whole hours to prepay (default 1; >= 1). FINAL once started: keep it at 1 and let auto-renew extend")
    b.add_argument("--no-auto-renew", action="store_true", help="do not renew hourly after this lease")
    b.add_argument("--fund", action="store_true",
                   help="advanced: deposit directly from this key first (needs ETH for gas; srnet topup is gas-free)")
    b.add_argument("--spool", help="directory to drop the claim JSON for the seller watcher")
    b.add_argument("--mock", action="store_true")

    x = sub.add_parser("renew", help="hourly auto-renew step (or --loop)")
    x.add_argument("--rpc")
    x.add_argument("--private-key")
    x.add_argument("--loop", action="store_true")
    x.add_argument("--interval", type=int, default=60)
    x.add_argument("--window", type=int, default=chain.RENEW_WINDOW,
                   help="renew when the current lease has at most this many seconds left (max 3600)")
    sub.add_parser("stop", help="stop hourly auto-renew (current paid hour runs out; no refund)")

    c = sub.add_parser("connect", help="MapExit full_tunnel; if the exit does not work: unmap, stop renewing")
    c.add_argument("seller")
    c.add_argument("--client-sesh", required=True)
    c.add_argument("--rpc")
    c.add_argument("--private-key")
    c.add_argument("--rpc-endpoint", help="session-router OMQ URL")
    c.add_argument("--timeout", type=float, default=90)
    c.add_argument("--wan-if")
    c.add_argument("--no-killswitch", action="store_true")
    c.add_argument("--allow-no-ks", action="store_true")
    c.add_argument("--resolv")
    c.add_argument("--spool")
    c.add_argument("--admission-flag", help="file written 'ok' when admission is ready (live harness)")
    c.add_argument("--mock", action="store_true")

    s = sub.add_parser("status")
    s.add_argument("--rpc-endpoint")

    d = sub.add_parser("disconnect")
    d.add_argument("--seller")
    d.add_argument("--rpc-endpoint")
    d.add_argument("--keep-killswitch", action="store_true")

    t = sub.add_parser("topup", help="top up: QR / send USDC from any wallet; gas-free deposit via your relayer")
    t.add_argument("--amount", type=float, required=True, help="USDC to wait for and deposit")
    t.add_argument("--all", action="store_true", help="deposit the whole wallet USDC balance once it arrives")
    t.add_argument("--contract")
    t.add_argument("--relayer", help="relayer URL (default: \"relayer\" in config.json, then $SRNET_RELAYER)")
    t.add_argument("--relay-fee", type=int, default=50_000, help="max relayer fee, USDC base units (default 0.05)")
    t.add_argument("--timeout", type=float, default=1800)
    t.add_argument("--rpc")
    t.add_argument("--private-key")

    sub.add_parser("deliver", help="retry sending your last claim to the seller over Session Router")

    co = sub.add_parser("cashout", help="withdraw unused SRNet balance (gas-free with a relayer)")
    co.add_argument("--amount", required=True, help="USDC, e.g. 5.00")
    co.add_argument("--to", help="destination address (default: your SRNet wallet)")
    co.add_argument("--yes", action="store_true", help="skip the confirm prompt")
    co.add_argument("--contract")
    co.add_argument("--rpc")
    co.add_argument("--private-key")

    py = sub.add_parser("pay", help="pay a seller from your SRNet balance (asks to confirm)")
    py.add_argument("--vendor-id", required=True)
    py.add_argument("--amount", required=True, help="USDC, e.g. 2.50 (max 20 per payment)")
    py.add_argument("--purpose", default="shop", choices=["shop", "file", "room", "exit"])
    py.add_argument("--item", help="what you're buying (shown in the prompt)")
    py.add_argument("--yes", action="store_true", help="skip the confirm prompt")
    py.add_argument("--contract"); py.add_argument("--rpc"); py.add_argument("--private-key")

    vd = sub.add_parser("vendor", help="seller: bind a vendor id to your wallet for SRNet-balance payments")
    vd.add_argument("--shop-key", help="your store seller key (64 hex); derives the salt")
    vd.add_argument("--salt", help="32-byte hex salt (default random)")
    vd.add_argument("--dry-run", action="store_true", help="print the vendor id only")
    vd.add_argument("--yes", action="store_true")
    vd.add_argument("--contract"); vd.add_argument("--rpc"); vd.add_argument("--private-key")

    u = sub.add_parser("ui", help="the SRNet app on 127.0.0.1: SNApps, Exits, Wallet (opens your browser); the default")
    sn = sub.add_parser("snapps", help="alias of ui")
    for x in (u, sn):
        x.add_argument("--no-browser", action="store_true", help="print the URL only")
        x.add_argument("--rpc", help="JSON-RPC URL for the wallet (default $SRNET_RPC, else Arbitrum One public RPC)")
        x.add_argument("--legacy-page", action="store_true", help=argparse.SUPPRESS)
        x.add_argument("--config", help="your client.json, layered on the shipped defaults "
                       "(default <home>/client.json if it exists)")
        x.add_argument("--data", help="data dir (default <home>/snapps)")
        x.add_argument("--port", type=int, default=48920)
    sn.set_defaults(no_browser=True)  # old behaviour: `srnet snapps` didn't open a browser

    op = sub.add_parser("open", help="open an srnet:// link in the SNApps client (shows the join sheet)")
    op.add_argument("link")
    op.add_argument("--port", type=int, default=48920)
    op.add_argument("--print-only", action="store_true", help="print the URL, don't open a browser")
    ml = sub.add_parser("mail", help="sealed mail: hosts, address, send, fetch, list, read (see: srnet mail -h)",
                        add_help=False)
    ml.add_argument("rest", nargs=argparse.REMAINDER)

    args, extra = ap.parse_known_args(argv)
    if args.cmd == "mail":
        args.rest = extra + args.rest
    elif extra:
        ap.error("unrecognized arguments: " + " ".join(extra))
    st = state.State(Path(args.home) if args.home else None)
    cmds = {
        "doctor": cmd_doctor,
        "key": cmd_key,
        "exits": cmd_exits,
        "buy": cmd_buy,
        "connect": cmd_connect,
        "renew": cmd_renew,
        "cashout": cmd_cashout,
        "stop": cmd_stop,
        "status": cmd_status,
        "disconnect": cmd_disconnect,
        "ui": cmd_ui,
        "open": cmd_open,
        "topup": cmd_topup,
        "snapps": cmd_ui,
        None: cmd_ui,
        "pay": cmd_pay,
        "deliver": cmd_deliver,
        "vendor": cmd_vendor,
        "mail": cmd_mail,
    }
    try:
        return cmds[args.cmd](args, st)
    except (chain.ChainError, keys.KeyError_) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
