// SPDX-License-Identifier: MIT
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
 */
contract ChatGC {
    address public owner;
    address public feeRecipient;
    uint256 public feeAmount;
    bool public paused;
    uint256 private _locked;

    /// Last message (encrypted for recipient) per recipient; recipient can fetch and decrypt off-chain.
    mapping(address => utString) public lastMessageForRecipient;

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

    error OnlyOwner();
    error InvalidRecipient();
    error InvalidFeeRecipient();
    error InsufficientFee();
    error TransferFailed();
    error WhenPaused();
    error ReentrancyGuard();

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
}
