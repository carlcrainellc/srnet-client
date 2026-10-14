# Changelog

## 0.1.0

Deployed to Arbitrum One at `0x07bbe156083EbBcc9435C721393Edd36a383E648` (tx `0xfb514a4f94049d1679b0c10ed3983be07b21151774b8a14257efa1432584637c`, block 514036941). Unaudited. Target chain is Arbitrum;
the testnet is Arbitrum Sepolia (421614).

- Leases are prepaid whole hours at the seller's hourly rate:
  `startLease(vendorId, ratePerHour, hours)`, 1 to `maxLeaseHours` hours,
  total capped by `maxPerLease`.
- Payment is final once a lease starts. There is no buyer cancel and no refund.
- Each hour is earned by the seller as it begins (`claimEarned`). After the end
  anyone can call `finalize`.
- Only the seller can `cancel`. It keeps the hours begun, the buyer gets unused
  whole hours back, and the lease can't be renewed.
- `renewLease(prevLeaseId, hours)` extends with the same buyer, seller and rate,
  starting when the previous lease ends. Allowed during the previous lease's
  last hour.
- Deposits via `fund(amount)` or a Chainflip CCM swap into `cfReceive`, which
  only the Vault can call and which never reverts for it. A fee of up to 3% is
  taken once at deposit and not refunded.
- CCM USDC with an unreadable message is held, not taken as fees. A 20-byte EVM
  source address can claim it with `claimHeld`; otherwise it stays in
  `unattributedUsdc`.
- Gasless `startLeaseFor`, `renewFor` and `withdrawFor` (EIP-712, domain
  version `1`) with a user-signed relay fee capped by `maxRelayFee`, unordered
  nonces and deadlines.
- Owner can transfer ownership (two-step), set the fee recipient, pause new
  deposits and leases, and rescue untracked non-USDC tokens. The owner can't
  move buyer, seller, relayer, held or unattributed USDC. `sweepSurplus` sends
  only USDC above `totalLiabilities` (direct transfers) to the fee recipient.
- Each lease can be renewed once (`renewedBy`, `AlreadyRenewed`).
- `withdrawPayable` is the clear name for withdrawing `payableOf` (seller
  earnings and relay fees); `withdrawVendor` stays as an identical alias.
- `cancel`, `finalize` and `claimEarned` are `nonReentrant`.
- Token and Vault are immutable; a Vault change means a new contract.
- Constructor: USDC, fee recipient, owner, `maxPerLease`, `maxLeaseHours`
  (<= 720), `feeBps` (<= 300), `cfVault`, `maxRelayFee`.
