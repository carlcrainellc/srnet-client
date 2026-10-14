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
- **One way to pay.** Exits, store items and future paid SNApps all use *Pay with SRNet
  balance*, confirmed in the app's own prompt.
- **Mail.** Sealed messages to anyone's SRNet address, stored by mail hosts until they come
  online. Hosts can't read your mail or see who sent it. Senders sign every message.
- **Private files.** File drops are encrypted on your computer before upload. Share with chosen
  people, with anyone who has the link, or publish unencrypted if you choose.

## Mail

Your mail address is your SRNet identity key plus the 1 to 3 mail hosts you pick, shared as a
`srnet://mail/...` link. Open **Mail** at the top of the SNApps sidebar, or use the command line:

```sh
srnet mail hosts http://<mail host> [http://<backup host>]   # set your hosts and register
srnet mail address --name "Alice"                            # your srnet://mail link to share
srnet mail send 'srnet://mail/...' -s "Hello" -m "Hi Bob"
srnet mail fetch && srnet mail list && srnet mail read <id>
srnet mail list requests && srnet mail accept <id>
srnet mail name 'srnet://room/...' "Bob's room"              # local petname for any srnet:// address
```

- Each message is signed with your key, then sealed to the recipient's key (X25519 +
  ChaCha20-Poly1305) and padded to a size bucket (1 KiB to 64 KiB). A mail host sees only
  the recipient key, the message id, the padded size and the time.
- Messages go to every host on the recipient's list; your client drops duplicates.
- Hosts keep mail 7 days by default (30 at most) and delete it only after your client has saved it and acknowledged it (fetch, then ack). Mail that is never acknowledged is deleted when it expires. Your
  client keeps it sealed on disk and opens it only to show it.
- Reading an inbox needs a fresh signed challenge from the owner's key. Nobody else can list
  or fetch it.
- Mail from your contacts goes to **Inbox**. Mail from anyone else goes to **Requests**, which
  has tighter limits (32 messages, 16 KiB each, 20 per hour). Accepting a sender moves them
  to your inbox on every host without telling the host who they are.
- **Attach** a file in the Mail page and it is encrypted on your computer and stored on a file
  drop you've joined (no public listing). Only the key-in-link goes inside the sealed message,
  so only your recipients can open it. Max 4 MiB per file. You can also paste file-drop links.
- Petnames are local only. Links can suggest a name; your own name always wins.

Wire format and host API: [`snapps/docs/MAIL.md`](snapps/docs/MAIL.md).

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

**Windows:** install Python 3.10+ (python.org or `winget install Python.Python.3.12`), then in
PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

It installs under `%LOCALAPPDATA%\srnet-client`, adds `srnet` to your PATH and an **SRNet** entry
to the Start menu. `-Uninstall` removes it. `srnet ui` and `srnet snapps` work on Windows;
`connect` is Linux-only.

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
srnet pay --vendor-id V --amount N   pay any SRNet seller from your balance
srnet vendor --shop-key K        seller: set up SRNet-balance payments
srnet deliver                    resend your exit claim to the seller
srnet status | stop | disconnect
srnet snapps --config F          the SNApps window
srnet key new|import|show        your encrypted wallet
srnet doctor                     check setup
```

Details: [client-cli/README.md](client-cli/README.md).

## Files

Uploads are encrypted by default (ChaCha20-Poly1305, a new random key per file, sizes padded to
buckets, name and type sealed inside). The host stores only ciphertext. Choose per file:

- **Only me and people I choose** (default): the file key is sealed to each person's key from
  their SRNet profile. Add people later, or approve someone's access request.
- **Anyone with the link**: the key rides in the link after `#`, so the host never sees it.
- **Not encrypted**: for content meant to be public and indexable.

Revoking someone stops them getting future versions. It can't take back a copy they already
downloaded.

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
- Store items are paid the same way: one payment from your SRNet balance to the seller, at most
  $20, no extra fee, final. Sellers run `srnet vendor --shop-key <key>` once and put the vendor id
  in their listings. Store payments from the SNApps window stay off on mainnet until you set
  `"payments": {"allow_mainnet": true}` in `client.json`.
- After you buy exit time, the client sends your signed claim straight to the seller over
  Session Router and waits for the seller's acknowledgment. `srnet deliver` resends it.

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

- Claim delivery needs sellers running the updated seller pack (`watcher --claim-listen`).
- SNApp card verification is optional and not bundled; card views report that.

## Security

See [SECURITY.md](SECURITY.md).

## License

Apache-2.0 for the exits client and contract, MIT for the SNApps client. See [LICENSE](LICENSE).

## Joining collections

The SNApps client starts with Home, Exits and Wallet in the ribbon. Everything else is something you joined:

- **Join**: on Home, paste a `.sesh` address (lists what that host offers) or an invite link
  `srnet://<name>.sesh/<type>/<collection>#root=<root key>`. The core fetches the host's signed delegation and
  shows the name, type, host and root key; nothing is saved until you click Join. Links are strictly validated
  (only `.sesh` hosts, known types, plain names, a 64-hex root).
- **Sidebar**: joined collections grouped by host, with unread counts. Rename, mute, pin, share and leave from the `⋯`
  menu. State lives in the client's `prefs.json`; no restart or config edit needed.
- **Trust on first use**: the root key is pinned the first time you join. If a host later presents a different root
  key, sync and posting stop and the collection shows ⚠. Re-trust is explicit (type "trust the new key") and wipes
  that collection's cache.
- **Share** makes an invite link carrying the pinned root key, so the receiver verifies the same key.
- **Directories** (`directory` type): hosts list their own collection by signing a `directory.entry` with that
  collection's root key (`snapps/scripts/directory_entry.py`); entries signed by anyone else are ignored.
- **Link handler**: `srnet open <link>` opens the join sheet in the running client. `install.sh` registers it for
  `srnet://` on Linux (xdg), `install.ps1` per-user on Windows (HKCU). macOS needs an app bundle to own a URL scheme,
  so there run `srnet open '<link>'` by hand.
- Collections from an existing `client.json` still load, as pre-joined and trusted with their configured pin.
