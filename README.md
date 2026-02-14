# ChatGC — Private instant messages + optional native COTI (COTI GC)

Smart contract on COTI V2 for **private instant messages** (chat). Clone of MemoGC; keeps chat and memos separate. Accepts encrypted messages via COTI privacy SDK and optional native COTI transfer. Fee is configurable and routed to a changeable fee recipient.

## Features

- **Private message**: `itString` message; validated on-chain and stored encrypted for the recipient (only they can decrypt via COTI SDK).
- **Optional native COTI**: Call `submit(recipient, message)` with `msg.value > 0`; fee (up to `feeAmount`) goes to `feeRecipient`, remainder to `recipient`.
- **Ownership**: Changeable via `transferOwnership(newOwner)` (owner-only).
- **Fee recipient**: Public and changeable via `setFeeRecipient(addr)` (owner-only).
- **Fee amount**: Public and changeable via `setFeeAmount(amount)` (owner-only).

## Build

```bash
cd chat-gc-contract
npm install
npm run compile
```

## Deploy

Set (optional):

- `DEPLOYER_PRIVATE_KEY` — used for `coti-mainnet` / `coti-testnet`.
- `COTI_RPC_URL` — default `https://mainnet.coti.io/rpc`.
- `CHAT_GC_OWNER` — initial owner (default: deployer).
- `CHAT_GC_FEE_RECIPIENT` — initial fee recipient (default: owner).
- `CHAT_GC_FEE_AMOUNT` — initial fee in wei (default: 0).

Then:

```bash
# Mainnet
npm run deploy:mainnet

# Testnet
npm run deploy:testnet

# Or with default hardhat network (local)
npm run deploy
```

## Client usage

1. Use `@coti-io/coti-ethers` to build a wallet and encrypt the message as `itString`.
2. Call `submit(recipient, message)` (and optionally send native COTI as `msg.value`).
3. Recipient can query `MessageSubmitted(recipient, from, messageForRecipient, messageForSender)` event logs; decode and decrypt with COTI SDK.

## Contract summary

| Item           | Visibility   | Changeable              |
|----------------|-------------|-------------------------|
| Owner          | Public      | Yes (`transferOwnership`) |
| Fee recipient  | Public      | Yes (`setFeeRecipient`)   |
| Fee amount     | Public      | Yes (`setFeeAmount`)      |
| Message        | Private     | N/A (per-call input)     |
| Native amount  | Public      | N/A (`msg.value`)         |

Network: COTI V2 (chainId 2632500). Explorer: https://mainnet.cotiscan.io

## Verify on CotiScan

1. Generate flattened source: `npm run flatten`
2. In CotiScan: Contract → Verify & Publish → Solidity (Single file)
3. Compiler: v0.8.19, Optimization: Yes, 200 runs
4. Paste contents of `ChatGC_flat.sol`
