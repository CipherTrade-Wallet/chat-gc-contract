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
    address public owner;
    address public feeRecipient;
    uint256 public feeAmount;
    bool public paused;
    uint256 private _locked;

    /// Last message (encrypted for recipient) per recipient; recipient can fetch and decrypt off-chain.
    mapping(address => utString) public lastMessageForRecipient;

    /// Conversation index: canonical id = keccak256(abi.encodePacked(min(a,b), max(a,b))).
    mapping(bytes32 => uint256) public lastBlockForConversation;
    mapping(bytes32 => uint256) public lastTimestampForConversation;

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
    /// Emitted for every submit; recipient and sender can query logs for full history or get receipt by tx hash and decrypt.
    event MessageSubmitted(
        address indexed recipient,
        address indexed from,
        utString messageForRecipient,
        utString messageForSender
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
        if (recipient == address(0)) revert InvalidRecipient();
        if (msg.value < feeAmount) revert InsufficientFee();

        gtString memory gtMessage = MpcCore.validateCiphertext(message);
        utString memory utRecipient = MpcCore.offBoardCombined(
            gtMessage,
            recipient
        );
        utString memory utSender = MpcCore.offBoardCombined(
            gtMessage,
            msg.sender
        );
        lastMessageForRecipient[recipient] = utRecipient;
        emit MessageSubmitted(recipient, msg.sender, utRecipient, utSender);

        (address low, address high) = msg.sender < recipient
            ? (msg.sender, recipient)
            : (recipient, msg.sender);
        bytes32 convId = keccak256(abi.encodePacked(low, high));
        lastBlockForConversation[convId] = block.number;
        lastTimestampForConversation[convId] = block.timestamp;

        uint256 value = msg.value;
        uint256 fee = feeAmount < value ? feeAmount : value;
        uint256 toRecipient = value - fee;

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

    /// Recipient can call this to get their last message (utString); decrypt off-chain with COTI SDK.
    function getLastMessage(
        address account
    ) external view returns (utString memory) {
        return lastMessageForRecipient[account];
    }

    /// Returns the block number of the last message between me and peer (either direction), or 0 if none.
    function getLastBlockForConversation(
        address me,
        address peer
    ) external view returns (uint256) {
        (address low, address high) = me < peer ? (me, peer) : (peer, me);
        return lastBlockForConversation[keccak256(abi.encodePacked(low, high))];
    }

    /// Returns the Unix timestamp of the last message between me and peer, or 0 if none.
    function getLastMessageTime(
        address me,
        address peer
    ) external view returns (uint256) {
        (address low, address high) = me < peer ? (me, peer) : (peer, me);
        return lastTimestampForConversation[keccak256(abi.encodePacked(low, high))];
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
