// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MixFinex
/// @notice On-chain music and remix exchange: list stems, place bids, fill offers, and split collaboration royalties. Bitfinex-style order flow for DJ remixes and shared tracks. Deploy once; roles and fee vault are fixed at construction.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract MixFinex is ReentrancyGuard, Ownable {

    event StemListed(
        bytes32 indexed stemId,
        address indexed lister,
        bytes32 contentHash,
        uint256 askWei,
        uint256 listedAtBlock,
        uint256 expiryBlock
    );
    event StemDelisted(bytes32 indexed stemId, address indexed lister, uint256 atBlock);
    event BidPlaced(
        bytes32 indexed bidId,
        bytes32 indexed stemId,
        address indexed bidder,
        uint256 bidWei,
        uint256 placedAtBlock,
        uint256 expiryBlock
    );
    event BidCancelled(bytes32 indexed bidId, address indexed bidder, uint256 atBlock);
    event OfferFilled(
        bytes32 indexed stemId,
        address indexed buyer,
        address indexed lister,
        uint256 paidWei,
        uint256 feeWei,
        uint256 atBlock
    );
    event BidFilled(
        bytes32 indexed bidId,
        bytes32 indexed stemId,
        address indexed seller,
        address bidder,
        uint256 receivedWei,
        uint256 feeWei,
        uint256 atBlock
    );
    event CollabInviteSent(
        bytes32 indexed collabId,
        bytes32 indexed stemId,
        address indexed inviter,
        address invitee,
        uint256 shareBps,
        uint256 atBlock
    );
    event CollabAccepted(bytes32 indexed collabId, address indexed invitee, uint256 atBlock);
    event CollabRejected(bytes32 indexed collabId, address indexed invitee, uint256 atBlock);
    event RoyaltySplit(
        bytes32 indexed stemId,
        address indexed recipient,
        uint256 amountWei,
        uint8 splitKind,
        uint256 atBlock
    );
    event FeeSwept(address indexed to, uint256 amountWei, uint8 vaultKind, uint256 atBlock);
    event ExchangePauseToggled(bool paused);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event MinListingWeiUpdated(uint256 previousWei, uint256 newWei, uint256 atBlock);
    event MaxListingWeiUpdated(uint256 previousWei, uint256 newWei, uint256 atBlock);
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    event StemAskUpdated(bytes32 indexed stemId, uint256 previousAsk, uint256 newAsk, uint256 atBlock);
    event BidAmountUpdated(bytes32 indexed bidId, uint256 previousWei, uint256 newWei, uint256 atBlock);
    event BatchStemsDelisted(bytes32[] stemIds, address indexed lister, uint256 atBlock);
    event BatchBidsCancelled(bytes32[] bidIds, address indexed bidder, uint256 atBlock);
    event ListingExpiryExtended(bytes32 indexed stemId, uint256 newExpiryBlock, uint256 atBlock);
    event DefaultExpiryBlocksUpdated(uint256 previousBlocks, uint256 newBlocks, uint256 atBlock);

    error MFX_ZeroAddress();
    error MFX_ZeroAmount();
    error MFX_ExchangePaused();
    error MFX_StemNotFound();
    error MFX_BidNotFound();
    error MFX_CollabNotFound();
    error MFX_NotLister();
    error MFX_NotBidder();
    error MFX_NotInviter();
    error MFX_NotInvitee();
    error MFX_NotKeeper();
    error MFX_InvalidFeeBps();
    error MFX_InvalidShareBps();
    error MFX_TransferFailed();
    error MFX_Reentrancy();
    error MFX_ListingExpired();
    error MFX_BidExpired();
    error MFX_AskMismatch();
    error MFX_BidMismatch();
    error MFX_BelowMinListing();
    error MFX_AboveMaxListing();
    error MFX_InsufficientValue();
    error MFX_AlreadyFilled();
    error MFX_AlreadyCancelled();
    error MFX_ArrayLengthMismatch();
    error MFX_BatchTooLarge();
    error MFX_ExpiryPast();
    error MFX_MaxListingsReached();
    error MFX_MaxBidsReached();
    error MFX_InvalidContentHash();
    error MFX_CollabAlreadyResponded();
    error MFX_ShareBpsOverflow();

    uint256 public constant MFX_BPS_DENOM = 10000;
    uint256 public constant MFX_MAX_FEE_BPS = 450;
    uint256 public constant MFX_MAX_LISTINGS_PER_USER = 128;
    uint256 public constant MFX_MAX_BIDS_PER_USER = 128;
    uint256 public constant MFX_EXCHANGE_SALT = 0x4C7e1B9a2F5d8E0c3A6b9D2e5F8a1C4d7E0b3A6;
    uint256 public constant MFX_MAX_BATCH_SIZE = 24;
    uint8 public constant MFX_VAULT_TREASURY = 1;
    uint8 public constant MFX_VAULT_FEE = 2;
    uint8 public constant MFX_SPLIT_COLLAB = 1;
    uint8 public constant MFX_SPLIT_ROYALTY = 2;
    uint256 public constant MFX_MIN_EXPIRY_BLOCKS = 5;
