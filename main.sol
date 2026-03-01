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
    uint256 public constant MFX_MAX_EXPIRY_BLOCKS = 250000;

    address public immutable treasury;
    address public immutable feeVault;
    address public immutable exchangeKeeper;
    uint256 public immutable deployedBlock;
    bytes32 public immutable exchangeDomain;

    address public keeper;
    uint256 public feeBps;
    uint256 public minListingWei;
    uint256 public maxListingWei;
    uint256 public defaultExpiryBlocks;
    uint256 public stemSequence;
    uint256 public bidSequence;
    uint256 public collabSequence;
    bool public exchangePaused;

    struct StemListing {
        address lister;
        bytes32 contentHash;
        uint256 askWei;
        uint256 listedAtBlock;
        uint256 expiryBlock;
        bool filled;
        bool delisted;
    }

    struct BidRecord {
        bytes32 stemId;
        address bidder;
        uint256 bidWei;
        uint256 placedAtBlock;
        uint256 expiryBlock;
        bool filled;
        bool cancelled;
    }

    struct CollabInvite {
        bytes32 stemId;
        address inviter;
        address invitee;
        uint256 shareBps;
        uint256 sentAtBlock;
        bool accepted;
        bool rejected;
    }

    mapping(bytes32 => StemListing) public stems;
    mapping(bytes32 => BidRecord) public bids;
    mapping(bytes32 => CollabInvite) public collabs;
    mapping(address => bytes32[]) public stemIdsByLister;
    mapping(address => bytes32[]) public bidIdsByBidder;
    mapping(bytes32 => uint256) public stemIdIndexInListerList;
    mapping(bytes32 => uint256) public bidIdIndexInBidderList;
    mapping(bytes32 => uint256) public totalRoyaltyPaid;
    mapping(bytes32 => address[]) public collabParticipants;
    mapping(bytes32 => uint256) public stemVolumeWei;
    mapping(address => uint256) public listerVolumeWei;
    mapping(address => uint256) public bidderVolumeWei;
    mapping(bytes32 => uint256) public bidCountForStem;
    mapping(bytes32 => bytes32[]) public bidIdsForStem;
    mapping(address => uint256) public collabInvitesSent;
    mapping(address => uint256) public collabInvitesReceived;
    uint256 public totalVolumeWei;
    uint256 public totalFeesWei;
    uint256[] private _allStemIds;
    uint256[] private _allBidIds;
    uint256 private _feeTreasuryAccum;
    uint256 private _feeVaultAccum;

    modifier whenNotPaused() {
        if (exchangePaused) revert MFX_ExchangePaused();
        _;
    }

    constructor() {
        treasury = address(0x8F3a2C5e7B1d4F6a9c0E3b6D8f1A4c7E0b3D6f9);
        feeVault = address(0x2E6b9D4f8A1c3E5b7D0f2A4c6E8b1D3f5A7c9e0);
        exchangeKeeper = address(0xB5d8F1a3C6e9b2D5f8A1c4E7b0D3f6A9c2E5b8);
        deployedBlock = block.number;
        exchangeDomain = keccak256(abi.encodePacked("MixFinex_", block.chainid, block.prevrandao, MFX_EXCHANGE_SALT));
        keeper = msg.sender;
        feeBps = 35;
        minListingWei = 0.001 ether;
        maxListingWei = 500 ether;
        defaultExpiryBlocks = 50000;
    }

    function setExchangePaused(bool paused) external onlyOwner {
        exchangePaused = paused;
        emit ExchangePauseToggled(paused);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert MFX_ZeroAddress();
        address prev = keeper;
        keeper = newKeeper;
        emit KeeperUpdated(prev, newKeeper);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MFX_MAX_FEE_BPS) revert MFX_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps, block.number);
    }

    function setMinListingWei(uint256 newMin) external onlyOwner {
        uint256 prev = minListingWei;
        minListingWei = newMin;
        emit MinListingWeiUpdated(prev, newMin, block.number);
    }

    function setMaxListingWei(uint256 newMax) external onlyOwner {
        uint256 prev = maxListingWei;
        maxListingWei = newMax;
        emit MaxListingWeiUpdated(prev, newMax, block.number);
    }

