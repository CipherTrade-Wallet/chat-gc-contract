# ChatGC Chat App Integration Guide

This document is written for AI agents and app developers implementing `ChatGC` in a chat client. It describes the contract model, required COTI encryption flow, send/read logic, caching strategy, and common pitfalls.

## Contract Purpose

`ChatGC` is an on-chain private chat mailbox for COTI V2. A message is encrypted client-side with the COTI SDK, submitted on-chain, validated by the contract, offboarded for both sender and recipient, and stored in contract state. Sender and recipient can later fetch and decrypt the stored `utString` payloads.

The contract is not a centralized messaging backend. The chain is the source of truth for message metadata, indexes, and encrypted message chunks.

## Core Concepts

- `itString`: encrypted input produced by the COTI SDK before calling `submit` or `submitMultipart`.
- `utString`: encrypted output stored by the contract for a specific viewer. The app passes this value to the COTI SDK decrypt function.
- `messageId`: monotonic contract-local ID assigned to every submitted message. It is unique only inside one `ChatGC` deployment.
- `chunkCount`: number of encrypted chunks in a message. `1` means normal single-submit message.
- `valueSent`: total native COTI sent with the message.
- `feeTaken`: portion of `valueSent` retained as protocol fee.
- `tip`: `valueSent - feeTaken`; if positive, show as an attached native COTI tip.
- `ConversationPreview`: fast recent-chat row containing `peer`, latest `messageId`, `blockNumber`, and `timestamp`.
- Conversation message index: state-backed ordered `messageId[]` per `(me, peer)` conversation. This is the source of truth for thread loading and load-older pagination.

## Important Constants

Read these from the contract when possible, or keep client constants synchronized:

```solidity
MAX_CHUNK_CELLS = 3
MAX_SINGLE_MESSAGE_CELLS = 64
MAX_CHUNKS_PER_MESSAGE = 64
MAX_RECENT_CONVERSATIONS = 50
NICKNAME_MAX_BYTES = 32
```

Implementation meaning:

- Single `submit` may carry a larger encrypted payload, up to `MAX_SINGLE_MESSAGE_CELLS`.
- Multipart chunks must each be small, up to `MAX_CHUNK_CELLS`.
- Multipart is a fallback for payloads that do not fit single submit.
- Self-sends are rejected. `recipient == msg.sender` reverts with `InvalidRecipient`.

## ABI Surface Needed By Apps

Minimum send/read ABI:

```solidity
function submit(address recipient, itString message) external payable
function submitMultipart(address recipient, itString[] messages) external payable
function feeAmount() external view returns (uint256)
function getMessage(uint256 messageId) external view returns (MessageView)
function getMessageChunk(uint256 messageId, uint256 chunkIndex) external view returns (utString)
function getMessageMetadata(uint256 messageId) external view returns (...)
function inboxCount(address account) external view returns (uint256)
function sentCount(address account) external view returns (uint256)
function getInboxPage(address account, uint256 offset, uint256 limit) external view returns (uint256[])
function getSentPage(address account, uint256 offset, uint256 limit) external view returns (uint256[])
function getRecentConversations(address account, uint256 limit) external view returns (ConversationPreview[])
function conversationMessageCount(address me, address peer) external view returns (uint256)
function getConversationMessagePage(address me, address peer, uint256 offset, uint256 limit) external view returns (uint256[])
function getConversationBlockRange(address me, address peer) external view returns (uint256 firstBlock, uint256 lastBlock)
function getLastBlockForConversation(address me, address peer) external view returns (uint256)
function getLastMessageTime(address me, address peer) external view returns (uint256)
function nicknames(address user) external view returns (string)
function setMyNickname(string name) external
```

Event:

```solidity
event MessageSubmitted(
  uint256 indexed messageId,
  address indexed recipient,
  address indexed from,
  uint256 valueSent,
  uint256 feeTaken,
  uint32 chunkCount
)
```

## Plaintext Payload Format

The contract does not interpret message plaintext. The app owns the payload format.

Recommended rules:

- Keep plain text UTF-8.
- If the app needs replies, encode reply metadata before encryption.
- If the app needs image/file attachments, upload the encrypted binary elsewhere and put only a compact attachment marker in the chat plaintext.
- Use the same encode/decode function on sender and receiver.
- Avoid storing raw binary or large base64 images directly inside ChatGC messages.

Example app-level payloads:

```text
hello

[reply:0xabc123...] hello

hello [img:blob-id|aes-key:iv|12345|image/jpeg]
```

## Sending A Message

High-level send flow:

1. Validate wallet session and recipient address.
2. Reject self-send in the UI before calling the contract.
3. Build `payloadRaw` from the message body plus app-level metadata.
4. Get `feeAmount()` from the contract.
5. If sending a tip, set `msg.value = feeAmount + tipWei`; otherwise set `msg.value = feeAmount`.
6. Encrypt with the COTI SDK.
7. Choose `submit` when the encrypted cell count fits `MAX_SINGLE_MESSAGE_CELLS`.
8. Otherwise split into UTF-8-safe chunks, encrypt each chunk with the multipart selector, and call `submitMultipart`.
9. Track the local pending message by a stable client-side ID until the transaction receipt or fetched chain message reconciles it.
10. On receipt success, keep the local row visible and refresh/reconcile with chain data.
11. On receipt failure, mark the local row failed; do not silently delete it.

Pseudo-code:

```ts
const payloadRaw = buildAppPayload(text, reply, attachment);
const feeWei = await contract.feeAmount();
const valueWei = feeWei + tipWei;

const single = await cotiWallet.encryptValue(
  encodePlaintext(payloadRaw),
  chatGcAddress,
  submitSelector,
);

if (single.ciphertext.value.length <= MAX_SINGLE_MESSAGE_CELLS) {
  await contract.submit(recipient, single, { value: valueWei });
} else {
  const chunks = splitUtf8Safe(payloadRaw, CHUNK_BYTES);
  if (chunks.length > MAX_CHUNKS_PER_MESSAGE) throw new Error("Message too long");

  const encryptedChunks = [];
  for (const chunk of chunks) {
    encryptedChunks.push(await cotiWallet.encryptValue(
      encodePlaintext(chunk),
      chatGcAddress,
      submitMultipartSelector,
    ));
  }
  await contract.submitMultipart(recipient, encryptedChunks, { value: valueWei });
}
```

Selector rule:

- Encrypt single-submit payloads with the `submit` selector.
- Encrypt multipart chunk payloads with the `submitMultipart` selector.
- Do not encrypt with one selector and call the other function.

## Multipart Strategy

Multipart is more expensive than single submit because each chunk is validated and offboarded separately for sender and recipient.

Use multipart only when the full encrypted payload exceeds the single-submit cell limit or the SDK reports a size/cell-count error.

Recommended chunking:

- Split by UTF-8 byte length, not JavaScript string length.
- Keep chunks small enough that encrypted chunk cell count stays <= `MAX_CHUNK_CELLS`.
- Current conservative chunk size is 16 UTF-8 bytes.
- Never split in the middle of a UTF-8 character.

Do not choose multipart just because plaintext is longer than 16 bytes. Always attempt single encrypt first.

## Reading Messages

Fast read by `messageId`:

1. Call `getMessage(messageId)` as the viewer address. The caller must be sender or recipient.
2. Decrypt returned `messageView.ciphertext`.
3. If `chunkCount > 1`, call `getMessageChunk(messageId, i)` for `i = 1..chunkCount-1`.
4. Decrypt every chunk.
5. Concatenate decoded chunk plaintext in order.
6. Decode app-level metadata such as replies, image tags, and tips.

Important:

- `getMessage(messageId)` only returns chunk `0`.
- For multipart messages, always fetch remaining chunks.
- `getMessageChunk` reverts with `UnauthorizedViewer` if caller is neither sender nor recipient.

Pseudo-code:

```ts
const first = await contract.getMessage(messageId, { from: viewer });
const parts = [await decrypt(first.ciphertext)];

for (let i = 1; i < first.chunkCount; i++) {
  const chunk = await contract.getMessageChunk(messageId, i, { from: viewer });
  parts.push(await decrypt(chunk));
}

const payloadRaw = parts.join("");
const message = decodeAppPayload(payloadRaw);
```

## Loading Recent Conversations

Use `getRecentConversations(account, limit)` for the first screen paint. It returns up to `MAX_RECENT_CONVERSATIONS` peers in most-recent-first order.

Recommended recent-list flow:

1. Load cached recents immediately from local storage.
2. Call `getRecentConversations(account, 20)`.
3. For each preview, use `peer`, `messageId`, `blockNumber`, and `timestamp`.
4. Hydrate display labels from local contacts, resolver/API, and `nicknames(peer)`.
5. Optionally fetch/decrypt the latest message preview by `messageId`.
6. Store the result locally with a short TTL.

Do not scan logs to build the recent list. The contract stores recent conversations in state.

## Loading A Thread

Recommended thread-load flow:

1. Load cached thread messages immediately.
2. Call `conversationMessageCount(me, peer)`.
3. Fetch the latest page with `getConversationMessagePage(me, peer, offset, limit)`.
4. Fetch/decrypt messages by `messageId`.
5. Merge fetched confirmed messages with local pending/failed messages.
6. Never drop pending messages just because a receipt is not available yet.

For the first page:

```ts
const count = await contract.conversationMessageCount(me, peer);
const pageLimit = Math.min(visibleLimit, count);
const offset = Math.max(0, count - pageLimit);
const ids = await contract.getConversationMessagePage(me, peer, offset, pageLimit);
```

For "load older":

1. Track the oldest confirmed message currently loaded.
2. Fetch the previous conversation page before that message.
3. Fetch/decrypt those older IDs.
4. Merge with current visible messages and keep pending/failed rows.

If the client only tracks `oldestBlock`, fetch pages moving backward and ignore metadata rows with `blockNumber >= oldestBlock`.

Do not use account-wide inbox/sent pages or event logs to load a selected thread. Those are not peer-specific and can stall on accounts with many unrelated messages.

`getConversationBlockRange(me, peer)` is still useful as lightweight metadata for UI/caches, but it is not the primary history loader.

Pending receipt rule:

- `getTransactionReceipt(txHash) === null` means still pending or not indexed.
- Only treat a tx as failed when a receipt exists and `receipt.status === 0`.

## Inbox And Sent Pagination

Mailbox indexes are state-backed:

```solidity
getInboxPage(account, offset, limit)
getSentPage(account, offset, limit)
```

Use these for account-wide recovery tools or non-thread-specific mailbox views only. Pages return `messageId[]`. Fetch message details with `getMessage` / `getMessageMetadata`.

Recommended approach:

- Fetch latest pages from both inbox and sent.
- Merge IDs.
- Sort by metadata block/timestamp.
- Determine peer from `(from, to)`.
- Decrypt only messages needed for the recovery view or preview.

Do not use inbox/sent pagination for normal thread loading when `conversationMessageCount` and `getConversationMessagePage` are available.

## Event-Based Notifications

Notify servers should subscribe to `MessageSubmitted`.

For each event:

- `recipient` receives an incoming message notification.
- `from` can receive a sent/sync data notification if the app uses multi-device sync.
- Include `messageId`, `from`, `recipient`, `txHash`, `blockNumber`, `valueSent`, `feeTaken`, and `chunkCount` in data payloads.

Do not rely on logs for app state. The contract stores recent peers, per-conversation message IDs, message metadata, and encrypted chunks in state, so clients can recover after missed notifications.

## Local Cache Requirements

A production app should cache:

- Recent conversations by `(account, chainId, chatGCAddress)`.
- Thread messages by `(account, chainId, chatGCAddress, peer)`.
- Last decrypted preview per peer.
- Last read block/message ID per peer.
- Pending messages by stable client-side ID.
- Known nickname values.
- COTI onboarding/AES context according to wallet security policy.

Cache invalidation:

- Clear chat caches when deleting account/wallet data.
- Clear per-thread cache when user clears a thread.
- Keep pending messages visible until receipt success/failure or explicit user action.
- Do not overwrite a richer local pending row with a partial chain fetch.

Message identity:

- `messageId` is a `uint256`, so overflow is not a practical concern.
- `messageId` resets on every new contract deployment.
- Never use raw `messageId` alone for cross-contract app identity, reaction identity, or long-lived caches.
- Use a scoped app key such as `chainId:chatGCAddress:messageId`.
- If another contract stores per-message data under `bytes32 id` (for example reactions), derive the ID from scoped data:

```ts
const messageKey = `message:${messageId}`;
const scopedMessageKey = `chat:${chainId}:${chatGCAddress.toLowerCase()}:${messageKey}`;
const reactionId = keccak256(toUtf8Bytes(scopedMessageKey));
```

This prevents reactions or cached metadata from an old deployment from applying to a new deployment whose `messageId` sequence starts again at `0`.

## Gas And UX Guidance

- `submit` is usually cheaper than `submitMultipart`.
- `submitMultipart` cost scales with chunk count.
- `estimateGas` is recommended when available, especially for payloads with attachments or multipart messages.
- If using a fixed gas floor, make it high enough for the largest supported payload or reject messages that exceed tested limits.
- Show pending states: queued, encrypting, signing, broadcasting, confirming, failed.
- Keep the message bubble visible in all pending states.
- If confirmation is slow, keep the row in `confirming`; do not remove it.

## Error Handling

Common contract errors:

- `InvalidRecipient`: zero address or self-send.
- `InsufficientFee`: `msg.value < feeAmount`.
- `WhenPaused`: owner paused submissions.
- `InvalidChunkCount`: multipart chunk count is zero or above `MAX_CHUNKS_PER_MESSAGE`.
- `ChunkTooLarge`: ciphertext cell count invalid or exceeds the relevant limit.
- `UnauthorizedViewer`: caller tried to read a message they did not send or receive.
- `TransferFailed`: native fee/tip transfer failed.

Client behavior:

- Normalize raw RPC errors into user-safe messages.
- Keep detailed errors in debug logs.
- For reverts, simulate the call when useful to decode revert reason.
- Do not show raw JSON parse errors or raw RPC blobs in UI.

## Security Notes

- Plaintext exists only client-side before encryption and after decryption.
- Recipient and sender addresses are public on-chain.
- Message timing, fee, tip amount, and chunk count are public.
- Nicknames are public and should be treated as untrusted user input.
- Sanitize all display text in web clients.
- Do not allow self-send unless the contract intentionally supports it; this contract rejects it.
- Do not leak COTI AES/private decrypt material to logs or remote telemetry.
- Attachment binaries should be encrypted before upload; store only encrypted blobs off-chain.
- Scope all off-chain or companion-contract message references by `chainId` and `chatGCAddress`; raw numeric `messageId` is contract-local.

## Implementation Checklist

Use this checklist for an AI coding agent implementing ChatGC:

1. Add ABI for send, mailbox, message reads, recent conversations, fees, nicknames, and events.
2. Implement COTI onboarding/key recovery before encrypt/decrypt.
3. Implement `encodePlaintext` / `decodePlaintext` consistently.
4. Implement single-first send path with selector-correct encryption.
5. Implement multipart fallback with UTF-8-safe chunking.
6. Include `feeAmount` in every send and optional tip as extra `msg.value`.
7. Add optimistic pending message before broadcast.
8. Update pending row through encrypting/signing/broadcasting/confirming.
9. Keep pending rows visible while receipt is null.
10. Mark failed only on explicit revert/timeout/error.
11. On receipt success, refresh/reconcile the thread.
12. Implement `getRecentConversations` for fast recents.
13. Implement thread loading through `conversationMessageCount` and `getConversationMessagePage`.
14. Fetch/decrypt all chunks for multipart messages.
15. Cache recents, thread messages, previews, pending rows, and read state under `(account, chainId, chatGCAddress)`.
16. Clear relevant caches on per-thread clear, global chat clear, and account delete.
17. Subscribe notify server to `MessageSubmitted`.
18. Include `messageId` and tx metadata in notification data payloads.
19. Scope reaction/companion IDs by `chainId + chatGCAddress + messageId`.
20. Test single text, long text, replies, attachment marker, tip-only, message+tip, multipart, slow pending, revert, redeploy ID collisions, and missed-notification recovery.

## Minimal TypeScript ABI Snippet

```ts
export const CHAT_GC_ABI = [
  "function submit(address recipient, ((uint256[] value), bytes[] signature) message) external payable",
  "function submitMultipart(address recipient, ((uint256[] value), bytes[] signature)[] messages) external payable",
  "function feeAmount() view returns (uint256)",
  "function getMessage(uint256 messageId) view returns (tuple(uint256 id,address from,address to,uint64 blockNumber,uint64 timestamp,uint32 chunkCount,uint256 valueSent,uint256 feeTaken,(tuple(uint256[] value) ciphertext,tuple(uint256[] value) userCiphertext) ciphertext))",
  "function getMessageChunk(uint256 messageId,uint256 chunkIndex) view returns ((tuple(uint256[] value) ciphertext,tuple(uint256[] value) userCiphertext) ciphertext)",
  "function getMessageMetadata(uint256 messageId) view returns (address from,address to,uint64 blockNumber,uint64 timestamp,uint32 chunkCount,uint256 valueSent,uint256 feeTaken)",
  "function inboxCount(address account) view returns (uint256)",
  "function sentCount(address account) view returns (uint256)",
  "function getInboxPage(address account,uint256 offset,uint256 limit) view returns (uint256[])",
  "function getSentPage(address account,uint256 offset,uint256 limit) view returns (uint256[])",
  "function getRecentConversations(address account,uint256 limit) view returns (tuple(address peer,uint256 messageId,uint64 blockNumber,uint64 timestamp)[])",
  "function conversationMessageCount(address me,address peer) view returns (uint256)",
  "function getConversationMessagePage(address me,address peer,uint256 offset,uint256 limit) view returns (uint256[])",
  "function getConversationBlockRange(address me,address peer) view returns (uint256 firstBlock,uint256 lastBlock)",
  "function getLastBlockForConversation(address me,address peer) view returns (uint256)",
  "function getLastMessageTime(address me,address peer) view returns (uint256)",
  "function nicknames(address user) view returns (string)",
  "function setMyNickname(string name)",
  "event MessageSubmitted(uint256 indexed messageId,address indexed recipient,address indexed from,uint256 valueSent,uint256 feeTaken,uint32 chunkCount)",
] as const;
```
