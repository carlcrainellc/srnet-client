# SRNet client

One app for SRNet: typed SNApps, the exit marketplace, and your SRNet balance.

- **SNApps.** Boards, chat rooms, wikis, storefronts, file drops, profiles and plain-HTML
  `.sesh` pages. Hosts serve only signed data; the client ships the interface. Every record is
  signature-checked, every template runs in a sandbox with no network access, and HTML pages
  open in a viewer that strips all scripts.
- **Exits.** Browse exit sellers from the signed exit board, buy an hour, auto-renew, and
  connect. The board is fetched from three `.sesh` names with failover and a verified cache.
- **Wallet / Top up.** Fund your SRNet balance from any phone wallet with a plain USDC send.
  No ETH needed.

## Install

Linux or macOS, Python 3.10 or newer.

```sh
git clone <this repository> srnet-client
cd srnet-client
./install.sh
srnet key new
srnet doctor
srnet ui
```

The installer puts everything under `~/.local/share/srnet-client` and adds `srnet` and
`srnet-relayer` to `~/.local/bin`. It needs no root. `./install.sh --uninstall` removes it and
keeps your wallet in `~/.srnet`.

Routing your traffic through an exit (`srnet connect`) uses nftables and is Linux-only.
Browsing SNApps, listing exits, buying leases and topping up work on macOS too.

**Windows:** not packaged yet. Under WSL2 (Ubuntu) `./install.sh` works as on Linux. Natively,
`pip install ./client-cli[qr]` and `python -m srnet ui` should give you exits, wallet and top-up (untested on Windows so far);
`connect` is not available on Windows.

## The app

`srnet ui` opens a local page on `127.0.0.1` with three tabs:

- **SNApps** links to the SNApps window started with `srnet snapps --config client.json`.
- **Exits** lists sellers with region, price per hour and last refresh, and has buttons to buy
  one hour, auto-renew, connect and disconnect.
- **Wallet / Top up** shows your wallet address, USDC, SRNet balance, and a QR code for topping
  up from a phone wallet.

The page only answers to the link it prints, and your keystore passphrase is used for the
action you click and never saved.

## Command line

```
srnet exits                      list sellers from the signed exit board
srnet buy <seller>               prepay one hour (--hours N for more)
srnet renew --loop               buy the next hour near the end of the current one
srnet connect <seller>           route traffic through the exit (Linux)
srnet topup --amount N           phone-wallet top-up
srnet status | stop | disconnect
srnet snapps --config F          the SNApps window
srnet key new|import|show        your encrypted wallet
srnet doctor                     check setup
```

Details: [client-cli/README.md](client-cli/README.md).

## Paying

Your SRNet balance lives in the SRNetBalance contract on Arbitrum One at
`0x7E0d01B7dd916BdAB96B0971ab92D160E1664431`. The source is verified on Sourcify.
The contract is unaudited; keep amounts small.

- Deposit fee: 3% of each deposit.
- Phone-wallet top-ups go through a relayer, which takes a flat fee (default 0.05 USDC; the
  contract caps it at 1 USDC). The relayer can't move your funds anywhere else or charge more
  than you signed.
- Leases are prepaid whole hours, at most $20 per lease. Payment is final once a lease starts.
  Buying one hour at a time keeps the most you can lose to about one hour.

No public relayer is configured by default. Set one in the Wallet tab, with
`srnet topup --relayer URL`, or run your own with `srnet-relayer`.

The previous contract `0x07bbe156083EbBcc9435C721393Edd36a383E648` stays live, so balances
there can still be cashed out.

## Testing

```sh
python3 -m unittest discover -s client-cli/tests           # exits, wallet, top-up, UI
(cd snapps/tests && python3 -m unittest)                    # typed SNApps
(cd contracts/srnet-balance && forge test)                  # contract (needs Foundry)
python3 scripts/smoke.py                                    # local end-to-end, loopback only
```

The smoke test runs the SNApps demo, lists exits from a locally signed board with a dead first
copy, and does a full phone-wallet top-up on a local anvil chain. It uses throwaway keys only.

## Known gaps

- Getting a buyer's signed claim to a remote seller isn't automatic yet; `buy` writes it to a
  local spool directory.
- SNApp card verification is optional and not bundled; card views report that.

## Security

See [SECURITY.md](SECURITY.md).

## License

Apache-2.0 for the exits client and contract, MIT for the SNApps client. See [LICENSE](LICENSE).
