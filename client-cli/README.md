# srnet

Linux command-line client for buying exit leases.

The contract is unaudited and live on Arbitrum One with real USDC. Use small
amounts.

## Install

Needs Python 3.10+.

```sh
cd client-cli
pip install .
srnet doctor
```

Dependencies: `cryptography`, `pyzmq`, `eth-account`, `eth-abi`. Chain access
is plain JSON-RPC over HTTPS; no Foundry needed. Without installing,
`python3 -m srnet` (or `srnet.sh`) works from this directory once the
dependencies are present.

Settings are read from flags, then `$SRNET_HOME/config.json` (`rpc`,
`keystore`, `listings_path`, `board_urls`, `board_pin`, `sesh_dns`, `spool`,
`omq`), then `SRNET_RPC`.

## Wallet

```sh
srnet key new        # new wallet, saved encrypted
srnet key import     # encrypt an existing key (prompted, not echoed)
srnet key show
```

The keystore is `$SRNET_HOME/keystore.json` (V3, scrypt; `--keystore` to
override). The passphrase is prompted, or read from `SRNET_KEYSTORE_PASSWORD`
for `renew --loop` under systemd. `--private-key` / `SRNET_PRIVATE_KEY` still
work, in plaintext, with a warning. `srnet doctor` shows which one is in use.

## Usage

```
srnet key new|import|show       manage the encrypted wallet keystore
srnet doctor                    check packages, RPC, chain, wallet, balances
srnet exits [--listings FILE]   list sellers from the signed board (or a local file)
srnet buy <seller> [--hours N]  prepay N hours (default 1) at the listed rate, writes a claim
srnet connect <seller>          MapExit full_tunnel; unmap and stop renewing if the exit doesn't work
srnet renew [--loop]            buy the next hour in the last 10 minutes of the current one
srnet stop                      stop auto-renew; the current hour runs out
srnet status
srnet disconnect                unmap and stop auto-renew
srnet ui [--no-browser]         local web page: board, balance, buy, auto-renew, connect
```

Example:

```sh
export SRNET_HOME=~/.srnet
export SRNET_RPC=https://arb1.arbitrum.io/rpc   # the default; testnets: point at their RPC
srnet key import
srnet exits
srnet buy <seller>.sesh --client-sesh <you>.sesh --fund \
  --spool /path/to/claim-dir
srnet connect <seller>.sesh --client-sesh <you>.sesh
srnet renew --loop
srnet status
srnet disconnect
```

Payment is final once a lease starts. There is no buyer cancel and no refund.
Keep `--hours` at 1 and let auto-renew extend it. If mapping fails or the exit
never becomes capable, the client unmaps and turns auto-renew off.

## Board

`srnet exits` fetches `board.json` and `board.sig` from these names, in order,
through Session Router:

```
exitsrjnc83har7a17mdtjpgi1j3odgiphaffe9ejfq4wnbdxkio.sesh
exitstaf5qs8so5g4ykzodhiyh79zjy3gqmszyzyhhm6r4szpwco.sesh
exitsdr3hzeqcwon7mqa7z87h8rn1j786uabdq5wzjw11us1nroo.sesh
```

The board must be signed by `qbhfd6kc4qijpdpjkd8nfcq55r377m1ff3o6ontfyikygsycywfo.sesh`.
Listings older than 3 hours, or with a bad seller signature, are dropped. If no
copy verifies, the last good board in `$SRNET_HOME/board-cache.json` is used
until it expires. `.sesh` names go through the system resolver first, then the
router's DNS listener at `sesh_dns` (default `127.0.0.1:5353`).

Output:

```
SELLER                                                   REGION  USDC/HR  LAST REFRESH
exit5...sesh                                             US      0.50     12m ago
```

## UI

`srnet ui` serves a page on 127.0.0.1 at a random port and opens it in
your browser. It has three tabs: SNApps, Exits and Wallet / Top up. It shows the board, wallet and deposit balance, time left, and has
buttons for buy 1 hour, auto-renew, connect and disconnect. The link carries a
one-time token; other local pages can't drive it. The keystore passphrase is
typed into the page for each action and isn't saved. Turning auto-renew on keeps
a `srnet renew --loop` running while the page is open.

For a menu entry on Ubuntu:

```sh
cp srnet-ui.desktop ~/.local/share/applications/
```

`connect` arms the nftables kill switch, which needs root. Run `srnet connect`
from a terminal with sudo if the button reports a permission error.

## Top up from a phone wallet

```sh
srnet topup --amount 10 --relayer http://127.0.0.1:8645
```

This shows a QR code (and the plain address) for **your own** SRNet wallet. Scan it with any
phone wallet and send plain USDC on Arbitrum One. No ETH is needed anywhere. When the USDC
arrives, the client signs a gas-free approval and a relayer deposits it into your SRNet
balance. The 3% deposit fee applies to the whole deposit, and the relayer takes a flat fee
(default 0.05 USDC, capped at 1 USDC by the contract). Without `--relayer` (or `relayer` in
`config.json` / `SRNET_RELAYER`) the signed request is printed so you can hand it to any relayer.

Anyone can run a relayer: `srnet-relayer --contract <address> --rpc <url>` with its own gas key
in `SRNET_RELAYER_KEY`. It can't redirect funds or charge more than the user signed.

## Claims

`buy` writes a signed claim (`hold-<id>.json`) into `--spool`. The seller's
watcher reads claims from its own spool directory. Remote delivery of claims to
a seller is not implemented yet, so for now the file has to reach the seller's
spool some other way, for example a shared directory. `connect` needs a prior
`buy` for that seller.

## Defaults

- An nftables kill switch drops clearnet TCP and DNS. UDP to the internet stays
  open for the overlay, so QUIC or WebRTC apps can bypass the exit.
- A first-run warning about what the exit operator can see. Type
  `I UNDERSTAND` to continue.
- System DNS is left alone. Plain DNS is blocked. Turn on DNS-over-HTTPS in
  your browser, or names won't resolve.
- Default chain is Arbitrum One with the live contract. Testnets are opt-in
  via `--rpc`; other chain ids are refused.

## vendor/

Copies of modules from
[session-router-exits-HOST](https://github.com/SRNet-lab/session-router-exits-HOST): the
listing verifier, the claim format and the connect flow. Don't edit them here.

## Tests

```sh
python3 -m unittest discover -s tests -v
```
