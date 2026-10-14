# SRNetBalance

USDC prepaid balance for SRNet exit leases on Arbitrum. Unaudited. Live on
Arbitrum One with real USDC; use small amounts.

Exit time is bought in prepaid whole hours at the seller's hourly rate. Payment
is final once a lease starts. There are no disputes, no arbiter and no operator
key.

## Deployment

Live on Arbitrum One (42161):

- SRNetBalance: `0x7E0d01B7dd916BdAB96B0971ab92D160E1664431` (adds `fundWithPermit` for gasless phone-wallet top-ups)
- Deploy tx: `0xa89abc5c2af92529f5bdb1f4c5e9e342e8c6799e00dca2d73a06ba868568db81` (block 514816032)
- Source: verified on Sourcify (exact match)
- USDC: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, fee 3%, $20 per lease, 168 h max, $1 max relay fee
- Previous deployment `0x07bbe156083EbBcc9435C721393Edd36a383E648` (no `fundWithPermit`) stays live; balances there can still be cashed out.

Unaudited. Keep amounts small.

## Build

```sh
forge install foundry-rs/forge-std   # once; lib/ is not committed
forge build
```

## Tests

```sh
forge test
```

Unit, fuzz, reentrancy, owner-power, CCM, signed-action and invariant tests.

## How it works

1. Deposit with `fund(amount)` or a Chainflip CCM swap into `cfReceive`. A fee
   set at deploy (at most 3%) is taken once, at deposit.
2. `startLease(vendorId, ratePerHour, hours)` locks `rate * hours` from the
   buyer's balance. Hours run from 1 to `maxLeaseHours`, and the total must not
   exceed `maxPerLease`.
3. `renewLease(prevLeaseId, hours)` buys more hours from the same seller at the
   same rate, starting when the previous lease ends (or now if it already
   ended). It can be called from the previous lease's last hour, and not after
   the seller stopped it.
4. Each hour belongs to the seller once it begins. The seller can call
   `claimEarned(leaseId)` at any time. After the end, anyone can call
   `finalize(leaseId)` to pay the seller the rest.
5. Only the seller can `cancel(leaseId)`. The seller keeps the hours already
   begun and the buyer gets every unused whole hour back.
6. Sellers and relayers call `withdrawPayable()` (`withdrawVendor()` is the
   same thing under the old name; relay fees land in the same `payableOf`).
   Buyers call `cashOut(amount)`, and anyone can call `withdrawFees()`, which
   pays the fee recipient.
7. Gasless actions: the buyer signs an EIP-712 `StartLease`, `Renew` or
   `Withdraw`, and anyone can submit it with `startLeaseFor`, `renewFor` or
   `withdrawFor` for the signed relay fee (capped by `maxRelayFee`). The
   EIP-712 domain is name `SRNetBalance`, version `1`.
8. CCM USDC with an unreadable message is held, never taken as fees. A 20-byte
   EVM `srcAddress` can claim it with `claimHeld(usdc)`. Anything else stays
   locked in `unattributedUsdc`, and the owner can't move it.

`renewLease` reads the rate back as `amount / hours`. That is exact, because
the lease stored `amount = rate * hours`.

USDC sent to the contract directly (not via `fund` or `cfReceive`) is owed to
nobody and shows as `surplusUsdc()`. `cfReceive` credits the amount the Vault
reports for that call, so a direct transfer isn't absorbed by a later CCM
deposit. The owner can `sweepSurplus()` it to the fee recipient; the sweep is
capped at `balance - totalLiabilities`.

The owner can transfer ownership (two-step), set the fee recipient, pause new
deposits and leases, rescue untracked non-USDC tokens and sweep USDC surplus.
Nothing else.

The token and the Chainflip Vault are immutable. If Chainflip replaces its
Vault, the fix is a new contract; balances in this one can still be cashed out.

## Deploy parameters

```
usdc, feeRecipient, owner,
maxPerLease, maxLeaseHours (<= 720), feeBps (<= 300),
cfVault, maxRelayFee
```

The tests use $20 per lease, 168 hours and 3%.

`script/DeployArbitrumOne.s.sol` pins Circle USDC
(`0xaf88d065e77c8cC2239327C5EDb3A432268e5831`) and the Chainflip Vault
(`0x79001a5e762f3bEFC8e5871b42F6734e00498920`, checked against its KeyManager)
on 42161. On other chains it takes `USDC` and `CF_VAULT` from env.
