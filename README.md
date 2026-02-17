# ChatGC — Private instant messages + optional native COTI (COTI GC)

Smart contract on COTI V2 for **private instant messages** (chat). Clone of MemoGC; keeps chat and memos separate. Accepts encrypted messages via COTI privacy SDK and optional native COTI transfer. Fee is configurable and routed to a changeable fee recipient.

## Features

- **Private message**: `itString` message; validated on-chain and stored encrypted for recipient and sender (both can decrypt via COTI SDK).
- **Optional native COTI**: Call `submit(recipient, message)` with `msg.value > 0`; fee (up to `feeAmount`) goes to `feeRecipient`, remainder to `recipient` as tip.
- **Pausable**: Owner can `pause()` / `unpause()` submissions; reverts with `WhenPaused` when paused.
- **Conversation index**: Per (me, peer) the contract stores last message block and timestamp. Use `getLastBlockForConversation(me, peer)` and `getLastMessageTime(me, peer)` for faster client loading (e.g. scan only from last block) and for “last message” / “has interacted” UI.
- **Nicknames**: Optional per-address display name. Call `setMyNickname(name)` to set or clear (empty string) your nickname; sanitized (printable ASCII, no `< > " ' & \`, max 32 bytes).
- **Ownership**: Changeable via `transferOwnership(newOwner)` (owner-only).
- **Fee recipient**: Public and changeable via `setFeeRecipient(addr)` (owner-only).
- **Fee amount**: Public and changeable via `setFeeAmount(amount)` (owner-only).
- **Reentrancy**: Protected with a reentrancy guard on `submit`.

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
3. Recipient and sender can query `MessageSubmitted(recipient, from, messageForRecipient, messageForSender)` event logs; decode and decrypt with COTI SDK.
4. Use `getLastBlockForConversation(me, peer)` and `getLastMessageTime(me, peer)` to scope log queries or show last-activity in UI; use `nicknames(addr)` for display names.

## Contract summary

| Item               | Visibility | Changeable                |
| ------------------ | ---------- | ------------------------- |
| Owner              | Public     | Yes (`transferOwnership`) |
| Fee recipient      | Public     | Yes (`setFeeRecipient`)   |
| Fee amount         | Public     | Yes (`setFeeAmount`)      |
| Paused             | Public     | Yes (`pause` / `unpause`) |
| Message            | Private    | N/A (per-call input)      |
| Native amount      | Public     | N/A (`msg.value`)         |
| Conversation index | Public     | No (updated on submit)    |
| Nicknames          | Public     | Yes (per user, `setMyNickname`) |

Network: COTI V2 (chainId 2632500). Explorer: https://mainnet.cotiscan.io

## Verify on CotiScan

1. Generate flattened source: `npm run flatten`
2. In CotiScan: Contract → Verify & Publish → Solidity (Single file)
3. Compiler: v0.8.19, Optimization: Yes, 200 runs
4. Paste contents of `ChatGC_flat.sol`

## License

This project is licensed under the **GNU General Public License v3.0 or later** (GPL-3.0-or-later).

You may use, copy, modify, and distribute this software under the terms of the GPL-3.0-or-later. A copy of the license is included in the [LICENSE](LICENSE) file in this repository.

See [https://www.gnu.org/licenses/gpl-3.0.html](https://www.gnu.org/licenses/gpl-3.0.html) for the full text and details.
