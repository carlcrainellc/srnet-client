# Gasless phone-wallet funding (fundWithPermit)

Flow: the client shows an EIP-681 QR of the user's own SRNet wallet (plain USDC transfer). The user sends
USDC from any phone wallet. No ETH is needed. When it arrives the client signs an EIP-2612 permit
(USDC -> SRNetBalance) and an EIP-712 `Fund` intent. Any relayer submits `fundWithPermit`.

    Fund(address owner,address beneficiary,uint256 amount,uint256 relayFee,address relayer,uint256 nonce,uint256 deadline)

Accounting: protocol fee = amount * feeBps (3%), as in `fund`. `relayFee` (<= immutable `maxRelayFee`,
$1, and <= amount after fee) goes to `payableOf[msg.sender]`. The rest goes to `availableOf[beneficiary]`.
Default relay fee is $0.05 (client default and relayer default minimum); measured gas per relayed
top-up is about $0.01 (214,563 gas on Arbitrum Sepolia). The 3% applies to the whole deposit.
`fund`, `cfReceive`, `startLeaseFor`, `renewFor`, `withdrawFor` are unchanged.

## Replay and front-running

- Replay: the intent uses the existing unordered `nonceUsed[owner][nonce]` and a deadline, under the
  SRNetBalance domain (chainId + contract address), so it can't be replayed on another chain or contract.
  `invalidateNonce` cancels a signed intent that hasn't been used yet. The USDC permit has its own sequential nonce.
- Redirect or overcharge: amount, beneficiary, relayFee and relayer are all signed. Changing any of them
  gives `BadSignature`. The fee is also capped on-chain by `maxRelayFee`.
- Permit griefing: anyone can copy the permit from the mempool and submit it to USDC first, which burns
  the permit nonce. `fundWithPermit` wraps `permit` in try/catch and then checks the allowance, so the
  front-run allowance is used and the top-up still goes through.
- Front-running the whole call: with `relayer = 0` another account can submit it first. The user's
  result is the same; only the account that collects the signed fee changes. Pin `relayer` to stop this.
- Permit-only allowance: no path pulls USDC from `owner` without the owner's Fund signature (`fund`
  pulls from msg.sender), so a standing allowance can't be spent by anyone else.
- Withholding: a relayer can sit on a request. It expires at `deadline` (client default 30 min), and
  the USDC stays in the user's wallet, so the user can re-sign for another relayer.

## Relayer (`client-cli/srnet/relayer.py`)

`SRNET_RELAYER_KEY=... python -m srnet.relayer --contract 0x.. --rpc ..`. It has its own gas key and
custody of nothing but its fee (inside the contract, withdrawn with `withdrawPayable`). It checks chain
and contract, enforces a minimum fee, refuses intents pinned to another relayer, rate-limits per IP and
per owner, simulates the call with eth_estimateGas, and enforces a per-tx gas cap and a rolling 24h gas
budget. It won't run on mainnet unless `SRNET_RELAYER_MAINNET=1` is set.
