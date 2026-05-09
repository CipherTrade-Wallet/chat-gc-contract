// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.19;

import "@coti-io/coti-contracts/contracts/utils/mpc/MpcCore.sol";

/**
 * ChatGC: Private instant messages + optional native COTI transfer with configurable fee.
 * Clone of MemoGC for chat use case; keeps memos and instant messages separate.
 * - Message: private (itString); validated and stored encrypted for recipient and sender (both can decrypt).
 * - Recipient: public (required by COTI; no private address type).
 * - Fee: msg.value must be >= feeAmount. Fee goes to feeRecipient; remainder (if any) to recipient as tip.
 * - Ownership, fee recipient and fee amount are public and changeable by owner.
 * - Pausable: owner can pause/unpause submissions.
 * - Conversation index: last block and timestamp per (me, peer) for faster loading and "has interacted" / last-msg date.
 * - Optional per-address nickname (sanitized); set by user for self.
 */
contract ChatGC {
    struct MessageRecord {
        bool exists;
        address from;
        address to;
        uint64 blockNumber;
        uint64 timestamp;
        uint32 chunkCount;
        uint256 valueSent;
        uint256 feeTaken;
    }

    struct MessageView {
        uint256 id;
        address from;
        address to;
        uint64 blockNumber;
        uint64 timestamp;
        uint32 chunkCount;
        uint256 valueSent;
        uint256 feeTaken;
        utString ciphertext;
    }

    struct ConversationPreview {
        address peer;
        uint256 messageId;
        uint64 blockNumber;
        uint64 timestamp;
    }

    address public owner;
    address public feeRecipient;
    uint256 public feeAmount;
    bool public paused;
    uint256 private _locked;
    uint256 public nextMessageId;

    uint8 public constant MAX_CHUNK_CELLS = 3;
    uint8 public constant MAX_SINGLE_MESSAGE_CELLS = 64;
    uint32 public constant MAX_CHUNKS_PER_MESSAGE = 64;
    uint256 public constant MAX_RECENT_CONVERSATIONS = 50;

    mapping(uint256 => MessageRecord) private _messages;
    mapping(uint256 => mapping(uint256 => utString)) private _recipientChunks;
    mapping(uint256 => mapping(uint256 => utString)) private _senderChunks;
    mapping(address => uint256[]) private _inboxMessageIds;
    mapping(address => uint256[]) private _sentMessageIds;

    /// Conversation index: canonical id = keccak256(abi.encodePacked(min(a,b), max(a,b))).
    mapping(bytes32 => uint256) public lastBlockForConversation;
    mapping(bytes32 => uint256) public lastTimestampForConversation;
    /// First message block per conversation (0 if none); lets clients bound getLogs range for history.
    mapping(bytes32 => uint256) public firstBlockForConversation;
    mapping(bytes32 => uint256) public lastMessageIdForConversation;
    mapping(address => address[]) private _recentConversationPeers;

    /// Optional nickname per address (empty string = none). Sanitized on set.
    mapping(address => string) public nicknames;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );
    event FeeRecipientSet(address indexed feeRecipient);
    event FeeAmountSet(uint256 feeAmount);
    event Paused();
    event Unpaused();
    event Submitted(
        address indexed recipient,
        uint256 valueSent,
        uint256 feeTaken
    );
    /// Emitted for every submit; clients should use messageId to fetch encrypted chunks from contract state.
    event MessageSubmitted(
        uint256 indexed messageId,
        address indexed recipient,
        address indexed from,
        uint256 valueSent,
        uint256 feeTaken,
        uint32 chunkCount
    );
    event NicknameSet(address indexed user, string nickname);

    error OnlyOwner();
    error InvalidRecipient();
    error InvalidFeeRecipient();
    error InsufficientFee();
    error TransferFailed();
    error WhenPaused();
    error ReentrancyGuard();
    error NicknameTooLong();
    error InvalidNickname();
    error InvalidChunkCount();
    error ChunkTooLarge();
    error MessageNotFound();
    error ChunkOutOfBounds();
    error UnauthorizedViewer();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert WhenPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 0) revert ReentrancyGuard();
        _locked = 1;
        _;
        _locked = 0;
    }

    constructor(
        address initialOwner_,
        address initialFeeRecipient_,
        uint256 initialFeeAmount_
    ) {
        if (initialOwner_ == address(0)) revert InvalidRecipient();
        if (initialFeeRecipient_ == address(0)) revert InvalidFeeRecipient();
        owner = initialOwner_;
        feeRecipient = initialFeeRecipient_;
        feeAmount = initialFeeAmount_;
        emit OwnershipTransferred(address(0), initialOwner_);
        emit FeeRecipientSet(initialFeeRecipient_);
        emit FeeAmountSet(initialFeeAmount_);
    }

    /// Transfer ownership to a new address.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidRecipient();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    /// Set the address that receives the fee (native COTI).
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == address(0)) revert InvalidFeeRecipient();
        feeRecipient = newFeeRecipient;
        emit FeeRecipientSet(newFeeRecipient);
    }

    /// Set the fee amount (in wei, native COTI). Public and changeable.
    function setFeeAmount(uint256 newFeeAmount) external onlyOwner {
        feeAmount = newFeeAmount;
        emit FeeAmountSet(newFeeAmount);
    }

    /// Pause submissions. Owner only.
    function pause() external onlyOwner {
        if (paused) return;
        paused = true;
        emit Paused();
    }

    /// Unpause submissions. Owner only.
    function unpause() external onlyOwner {
        if (!paused) return;
        paused = false;
        emit Unpaused();
    }

    /**
     * Submit a private message and optionally send native COTI to the recipient.
     * @param recipient Recipient (visible on-chain).
     * @param message Private message (itString); client must encrypt with COTI SDK before calling.
     * msg.value must be >= feeAmount. Fee goes to feeRecipient; remainder to recipient as tip.
     */
    function submit(
        address recipient,
        itString calldata message
    ) external payable whenNotPaused nonReentrant {
        _submitSingle(recipient, message);
    }

    function submitMultipart(
        address recipient,
        itString[] calldata messages
    ) external payable whenNotPaused nonReentrant {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (msg.value < feeAmount) revert InsufficientFee();
        uint256 chunkCount = messages.length;
        if (chunkCount == 0 || chunkCount > MAX_CHUNKS_PER_MESSAGE) revert InvalidChunkCount();

        (uint256 fee, uint256 toRecipient) = _splitValue();
        uint256 messageId = _createMessageRecord(recipient, chunkCount, msg.value, fee);
        for (uint256 i = 0; i < chunkCount; i++) {
            _storeChunk(messageId, i, recipient, messages[i], MAX_CHUNK_CELLS);
        }
        _finalizeSubmit(messageId, recipient, msg.value, fee, toRecipient, uint32(chunkCount));
    }

    function _submitSingle(
        address recipient,
        itString calldata message
    ) internal {
        if (recipient == address(0) || recipient == msg.sender) revert InvalidRecipient();
        if (msg.value < feeAmount) revert InsufficientFee();

        (uint256 fee, uint256 toRecipient) = _splitValue();
        uint256 messageId = _createMessageRecord(recipient, 1, msg.value, fee);
        _storeChunk(messageId, 0, recipient, message, MAX_SINGLE_MESSAGE_CELLS);
        _finalizeSubmit(messageId, recipient, msg.value, fee, toRecipient, 1);
    }

    function _splitValue() internal view returns (uint256 fee, uint256 toRecipient) {
        uint256 value = msg.value;
        fee = feeAmount < value ? feeAmount : value;
        toRecipient = value - fee;
    }

    function _createMessageRecord(
        address recipient,
        uint256 chunkCount,
        uint256 valueSent,
        uint256 feeTaken
    ) internal returns (uint256 messageId) {
        messageId = nextMessageId++;
        MessageRecord storage record = _messages[messageId];
        record.exists = true;
        record.from = msg.sender;
        record.to = recipient;
        record.blockNumber = uint64(block.number);
        record.timestamp = uint64(block.timestamp);
        record.chunkCount = uint32(chunkCount);
        record.valueSent = valueSent;
        record.feeTaken = feeTaken;
        _sentMessageIds[msg.sender].push(messageId);
        _inboxMessageIds[recipient].push(messageId);
    }

    function _storeChunk(
        uint256 messageId,
        uint256 chunkIndex,
        address recipient,
        itString calldata message,
        uint256 maxCells
    ) internal {
        _validateEncryptedChunk(message, maxCells);
        gtString memory gtMessage = MpcCore.validateCiphertext(message);
        utString memory utRecipient = MpcCore.offBoardCombined(gtMessage, recipient);
        utString memory utSender = MpcCore.offBoardCombined(gtMessage, msg.sender);
        _recipientChunks[messageId][chunkIndex] = utRecipient;
        _senderChunks[messageId][chunkIndex] = utSender;
    }

    function _finalizeSubmit(
        uint256 messageId,
        address recipient,
        uint256 value,
        uint256 fee,
        uint256 toRecipient,
        uint32 chunkCount
    ) internal {
        emit MessageSubmitted(messageId, recipient, msg.sender, value, fee, chunkCount);

        bytes32 convId = _conversationId(msg.sender, recipient);
        if (firstBlockForConversation[convId] == 0) firstBlockForConversation[convId] = block.number;
        lastBlockForConversation[convId] = block.number;
        lastTimestampForConversation[convId] = block.timestamp;
        lastMessageIdForConversation[convId] = messageId;
        _touchRecentConversation(msg.sender, recipient);
        _touchRecentConversation(recipient, msg.sender);

        if (fee > 0 && feeRecipient != address(0)) {
            (bool ok, ) = payable(feeRecipient).call{value: fee}("");
            if (!ok) revert TransferFailed();
        }
        if (toRecipient > 0) {
            (bool ok, ) = payable(recipient).call{value: toRecipient}("");
            if (!ok) revert TransferFailed();
        }
        emit Submitted(recipient, value, fee);
    }

    function inboxCount(address account) external view returns (uint256) {
        return _inboxMessageIds[account].length;
    }

    function sentCount(address account) external view returns (uint256) {
        return _sentMessageIds[account].length;
    }

    function getInboxPage(
        address account,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory messageIds) {
        return _slice(_inboxMessageIds[account], offset, limit);
    }

    function getSentPage(
        address account,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory messageIds) {
        return _slice(_sentMessageIds[account], offset, limit);
    }

    function getMessageMetadata(
        uint256 messageId
    )
        external
        view
        returns (
            address from,
            address to,
            uint64 blockNumber,
            uint64 timestamp,
            uint32 chunkCount,
            uint256 valueSent,
            uint256 feeTaken
        )
    {
        MessageRecord storage record = _requireMessage(messageId);
        return (record.from, record.to, record.blockNumber, record.timestamp, record.chunkCount, record.valueSent, record.feeTaken);
    }

    function getMessage(uint256 messageId) external view returns (MessageView memory messageView) {
        MessageRecord storage record = _requireMessage(messageId);
        return MessageView({
            id: messageId,
            from: record.from,
            to: record.to,
            blockNumber: record.blockNumber,
            timestamp: record.timestamp,
            chunkCount: record.chunkCount,
            valueSent: record.valueSent,
            feeTaken: record.feeTaken,
            ciphertext: _messageCiphertextForViewer(messageId, record, msg.sender, 0)
        });
    }

    function getMessageChunk(
        uint256 messageId,
        uint256 chunkIndex
    ) external view returns (utString memory ciphertext) {
        MessageRecord storage record = _requireMessage(messageId);
        return _messageCiphertextForViewer(messageId, record, msg.sender, chunkIndex);
    }

    function getMessageChunkCount(uint256 messageId) external view returns (uint256) {
        MessageRecord storage record = _requireMessage(messageId);
        return record.chunkCount;
    }

    function getRecentConversations(
        address account,
        uint256 limit
    ) external view returns (ConversationPreview[] memory previews) {
        address[] storage peers = _recentConversationPeers[account];
        uint256 count = peers.length;
        if (limit < count) count = limit;
        if (count > MAX_RECENT_CONVERSATIONS) count = MAX_RECENT_CONVERSATIONS;
        previews = new ConversationPreview[](count);
        for (uint256 i = 0; i < count; i++) {
            address peer = peers[i];
            bytes32 convId = _conversationId(account, peer);
            previews[i] = ConversationPreview({
                peer: peer,
                messageId: lastMessageIdForConversation[convId],
                blockNumber: uint64(lastBlockForConversation[convId]),
                timestamp: uint64(lastTimestampForConversation[convId])
            });
        }
    }

    /// Returns the block number of the last message between me and peer (either direction), or 0 if none.
    function getLastBlockForConversation(
        address me,
        address peer
    ) external view returns (uint256) {
        return lastBlockForConversation[_conversationId(me, peer)];
    }

    /// Returns the Unix timestamp of the last message between me and peer, or 0 if none.
    function getLastMessageTime(
        address me,
        address peer
    ) external view returns (uint256) {
        return lastTimestampForConversation[_conversationId(me, peer)];
    }

    /// Returns the block number of the first message between me and peer, or 0 if none. Use as lower bound for getLogs when loading full thread.
    function getFirstBlockForConversation(
        address me,
        address peer
    ) external view returns (uint256) {
        return firstBlockForConversation[_conversationId(me, peer)];
    }

    /// Returns (firstBlock, lastBlock) for the conversation between me and peer. Use for getLogs range [firstBlock, lastBlock].
    function getConversationBlockRange(address me, address peer) external view returns (uint256 firstBlock, uint256 lastBlock) {
        bytes32 convId = _conversationId(me, peer);
        return (firstBlockForConversation[convId], lastBlockForConversation[convId]);
    }

    function _touchRecentConversation(address user, address peer) internal {
        if (peer == address(0) || peer == user) return;
        address[] storage peers = _recentConversationPeers[user];
        uint256 len = peers.length;
        for (uint256 i = 0; i < len; i++) {
            if (peers[i] == peer) {
                for (uint256 j = i; j > 0; j--) {
                    peers[j] = peers[j - 1];
                }
                peers[0] = peer;
                return;
            }
        }
        peers.push(peer);
        len = peers.length;
        for (uint256 j = len - 1; j > 0; j--) {
            peers[j] = peers[j - 1];
        }
        peers[0] = peer;
        if (peers.length > MAX_RECENT_CONVERSATIONS) {
            peers.pop();
        }
    }

    function _conversationId(address a, address b) internal pure returns (bytes32) {
        (address low, address high) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(low, high));
    }

    function _messageCiphertextForViewer(
        uint256 messageId,
        MessageRecord storage record,
        address viewer,
        uint256 chunkIndex
    ) internal view returns (utString memory ciphertext) {
        if (chunkIndex >= record.chunkCount) revert ChunkOutOfBounds();
        if (viewer == record.from) return _senderChunks[messageId][chunkIndex];
        if (viewer == record.to) return _recipientChunks[messageId][chunkIndex];
        revert UnauthorizedViewer();
    }

    function _requireMessage(uint256 messageId) internal view returns (MessageRecord storage record) {
        record = _messages[messageId];
        if (!record.exists) revert MessageNotFound();
    }

    function _validateEncryptedChunk(itString calldata encryptedChunk, uint256 maxCells) internal pure {
        uint256 cells = encryptedChunk.ciphertext.value.length;
        if (
            cells == 0 ||
            cells != encryptedChunk.signature.length ||
            cells > maxCells
        ) {
            revert ChunkTooLarge();
        }
    }

    function _slice(
        uint256[] storage source,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory page) {
        if (offset >= source.length || limit == 0) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > source.length) end = source.length;
        page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = source[i];
        }
    }

    uint256 public constant NICKNAME_MAX_BYTES = 32;

    /// Set or clear the caller's nickname. Empty string clears. Reverts on invalid content or length.
    function setMyNickname(string calldata name) external {
        string memory sanitized = _sanitizeNickname(name);
        nicknames[msg.sender] = sanitized;
        emit NicknameSet(msg.sender, sanitized);
    }

    /// Allowed: printable ASCII except < > " ' & \ and control chars (0x00-0x1F, 0x7F). Max NICKNAME_MAX_BYTES. Trimmed.
    function _sanitizeNickname(string calldata name) internal pure returns (string memory) {
        bytes calldata b = bytes(name);
        uint256 len = b.length;
        if (len > NICKNAME_MAX_BYTES) revert NicknameTooLong();
        uint256 start = 0;
        while (start < len && (uint8(b[start]) <= 0x20 || b[start] == 0x7F)) start++;
        uint256 end = len;
        while (end > start && (uint8(b[end - 1]) <= 0x20 || b[end - 1] == 0x7F)) end--;
        if (start >= end) return ""; // after trim, empty is allowed (clears nickname)
        uint256 outLen = end - start;
        if (outLen > NICKNAME_MAX_BYTES) revert NicknameTooLong();
        bytes memory out = new bytes(outLen);
        for (uint256 i = 0; i < outLen; i++) {
            bytes1 c = b[start + i];
            if (uint8(c) <= 0x20 || c == 0x7F) revert InvalidNickname();
            if (c == "<" || c == ">" || c == 0x22 || c == 0x27 || c == "&" || c == "\\") revert InvalidNickname();
            out[i] = c;
        }
        return string(out);
    }
}
