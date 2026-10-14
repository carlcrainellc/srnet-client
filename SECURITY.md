# Security

## Reporting

Report vulnerabilities through a private security advisory:
https://github.com/SRNet-lab/srnet-client/security/advisories/new

Please don't open public issues for unfixed admission, signature or fund-loss
bugs.

## Design notes

The client kill switch is an nftables `inet` table with a drop policy on
output. DNS (tcp/udp 53) is dropped explicitly before the WAN UDP rule that the
overlay needs. The client doesn't change system DNS, and exits never forward
port 53.

The contract has no operator key. These are fixed at deploy: `maxPerLease`,
`maxLeaseHours` (at most 720), `feeBps` (at most 300), `cfVault` and
`maxRelayFee`. `cashOut` returns available balance only; the deposit fee is not
refunded.

Exit admission, the seller installer and its firewall are covered in
[session-router-exits-HOST](https://github.com/SRNet-lab/session-router-exits-HOST)'s
SECURITY.md.

## Known limitations

- The overlay needs UDP on the WAN interface. DNS is dropped, but other UDP is
  allowed, so QUIC or WebRTC apps can bypass the exit while the kill switch is
  on.
- `vendorId` is `keccak256(abi.encodePacked(wallet, salt))`, fixed at
  `configureVendor`. Don't reuse a salt across wallets.
- Leases are prepaid whole hours and final once started. The buyer can't cancel
  and gets no refund. Each hour belongs to the seller as it begins. The client
  buys one hour at a time and renews hourly, so a buyer can lose about one hour
  (and never more than `maxPerLease`). Only the seller can stop a lease early,
  and then the buyer gets unused whole hours back.
- There are no disputes and no arbiter. The owner can only transfer ownership,
  change the fee recipient, pause new deposits and leases, and rescue non-USDC
  tokens.
- Chainflip CCM USDC that arrives with an unreadable message is held, not taken
  as fees. A 20-byte EVM sender can claim it; otherwise it stays locked.
- The buyer supplies the hourly rate. The seller's watcher refuses leases below
  the listed rate.
- The contract is unaudited and live on Arbitrum One with real USDC. Use
  small amounts. The client refuses chain ids other than Arbitrum One, Arbitrum
  Sepolia and the test chains.
- The buyer key is stored in an encrypted V3 keystore by default. Plaintext
  keys via flag or env still work and print a warning.
