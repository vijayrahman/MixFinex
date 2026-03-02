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

    function setDefaultExpiryBlocks(uint256 newBlocks) external onlyOwner {
        if (newBlocks < MFX_MIN_EXPIRY_BLOCKS || newBlocks > MFX_MAX_EXPIRY_BLOCKS) revert MFX_ExpiryPast();
        uint256 prev = defaultExpiryBlocks;
        defaultExpiryBlocks = newBlocks;
        emit DefaultExpiryBlocksUpdated(prev, newBlocks, block.number);
    }

    function _stemId(bytes32 contentHash_, address lister_, uint256 seq_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(contentHash_, lister_, seq_));
    }

    function _bidId(bytes32 stemId_, address bidder_, uint256 bidWei_, uint256 seq_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(stemId_, bidder_, bidWei_, seq_));
    }

    function _collabId(bytes32 stemId_, address inviter_, address invitee_, uint256 seq_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(stemId_, inviter_, invitee_, seq_));
    }

    function listStem(bytes32 contentHash, uint256 askWei) external whenNotPaused nonReentrant returns (bytes32 stemId) {
        if (contentHash == bytes32(0)) revert MFX_InvalidContentHash();
        if (askWei < minListingWei) revert MFX_BelowMinListing();
        if (askWei > maxListingWei) revert MFX_AboveMaxListing();
        bytes32[] storage list = stemIdsByLister[msg.sender];
        if (list.length >= MFX_MAX_LISTINGS_PER_USER) revert MFX_MaxListingsReached();

        stemSequence++;
        stemId = _stemId(contentHash, msg.sender, stemSequence);
        if (stems[stemId].lister != address(0)) revert MFX_StemNotFound();

        uint256 expiry = block.number + defaultExpiryBlocks;
        stems[stemId] = StemListing({
            lister: msg.sender,
            contentHash: contentHash,
            askWei: askWei,
            listedAtBlock: block.number,
            expiryBlock: expiry,
            filled: false,
            delisted: false
        });
        stemIdIndexInListerList[stemId] = list.length;
        list.push(stemId);
        _allStemIds.push(stemSequence);
        emit StemListed(stemId, msg.sender, contentHash, askWei, block.number, expiry);
        return stemId;
    }

    function listStemWithExpiry(bytes32 contentHash, uint256 askWei, uint256 expiryBlock) external whenNotPaused nonReentrant returns (bytes32 stemId) {
        if (expiryBlock <= block.number) revert MFX_ExpiryPast();
        if (expiryBlock - block.number < MFX_MIN_EXPIRY_BLOCKS || expiryBlock - block.number > MFX_MAX_EXPIRY_BLOCKS) revert MFX_ExpiryPast();
        if (contentHash == bytes32(0)) revert MFX_InvalidContentHash();
        if (askWei < minListingWei) revert MFX_BelowMinListing();
        if (askWei > maxListingWei) revert MFX_AboveMaxListing();
        bytes32[] storage list = stemIdsByLister[msg.sender];
        if (list.length >= MFX_MAX_LISTINGS_PER_USER) revert MFX_MaxListingsReached();

        stemSequence++;
        stemId = _stemId(contentHash, msg.sender, stemSequence);
        if (stems[stemId].lister != address(0)) revert MFX_StemNotFound();

        stems[stemId] = StemListing({
            lister: msg.sender,
            contentHash: contentHash,
            askWei: askWei,
            listedAtBlock: block.number,
            expiryBlock: expiryBlock,
            filled: false,
            delisted: false
        });
        stemIdIndexInListerList[stemId] = list.length;
        list.push(stemId);
        _allStemIds.push(stemSequence);
        emit StemListed(stemId, msg.sender, contentHash, askWei, block.number, expiryBlock);
        return stemId;
    }

    function delistStem(bytes32 stemId) external whenNotPaused nonReentrant {
        StemListing storage s = stems[stemId];
        if (s.lister != msg.sender) revert MFX_NotLister();
        if (s.filled) revert MFX_AlreadyFilled();
        if (s.delisted) revert MFX_AlreadyCancelled();
        s.delisted = true;
        emit StemDelisted(stemId, msg.sender, block.number);
    }

    function extendStemExpiry(bytes32 stemId, uint256 newExpiryBlock) external whenNotPaused {
        StemListing storage s = stems[stemId];
        if (s.lister != msg.sender) revert MFX_NotLister();
        if (s.filled || s.delisted) revert MFX_StemNotFound();
        if (newExpiryBlock <= block.number || newExpiryBlock <= s.expiryBlock) revert MFX_ExpiryPast();
        if (newExpiryBlock - block.number > MFX_MAX_EXPIRY_BLOCKS) revert MFX_ExpiryPast();
        s.expiryBlock = newExpiryBlock;
        emit ListingExpiryExtended(stemId, newExpiryBlock, block.number);
    }

    function updateStemAsk(bytes32 stemId, uint256 newAskWei) external whenNotPaused {
        StemListing storage s = stems[stemId];
        if (s.lister != msg.sender) revert MFX_NotLister();
        if (s.filled || s.delisted) revert MFX_StemNotFound();
        if (block.number >= s.expiryBlock) revert MFX_ListingExpired();
        if (newAskWei < minListingWei) revert MFX_BelowMinListing();
        if (newAskWei > maxListingWei) revert MFX_AboveMaxListing();
        uint256 prev = s.askWei;
        s.askWei = newAskWei;
        emit StemAskUpdated(stemId, prev, newAskWei, block.number);
    }

    function batchDelistStems(bytes32[] calldata stemIds) external whenNotPaused nonReentrant {
        if (stemIds.length > MFX_MAX_BATCH_SIZE) revert MFX_BatchTooLarge();
        for (uint256 i = 0; i < stemIds.length; i++) {
            StemListing storage s = stems[stemIds[i]];
            if (s.lister == msg.sender && !s.filled && !s.delisted) {
                s.delisted = true;
            }
        }
        emit BatchStemsDelisted(stemIds, msg.sender, block.number);
    }

    function placeBid(bytes32 stemId, uint256 bidWei) external payable whenNotPaused nonReentrant returns (bytes32 bidId) {
        if (stems[stemId].lister == address(0)) revert MFX_StemNotFound();
        if (stems[stemId].filled || stems[stemId].delisted) revert MFX_StemNotFound();
        if (block.number >= stems[stemId].expiryBlock) revert MFX_ListingExpired();
        if (bidWei < minListingWei) revert MFX_BelowMinListing();
        if (bidWei > maxListingWei) revert MFX_AboveMaxListing();
        if (msg.value < bidWei) revert MFX_InsufficientValue();
        bytes32[] storage list = bidIdsByBidder[msg.sender];
        if (list.length >= MFX_MAX_BIDS_PER_USER) revert MFX_MaxBidsReached();

        bidSequence++;
        bidId = _bidId(stemId, msg.sender, bidWei, bidSequence);
        if (bids[bidId].bidder != address(0)) revert MFX_BidNotFound();

        uint256 expiry = block.number + defaultExpiryBlocks;
        bids[bidId] = BidRecord({
            stemId: stemId,
            bidder: msg.sender,
            bidWei: bidWei,
            placedAtBlock: block.number,
            expiryBlock: expiry,
            filled: false,
            cancelled: false
        });
        bidIdIndexInBidderList[bidId] = list.length;
        list.push(bidId);
        bidCountForStem[stemId]++;
        bidIdsForStem[stemId].push(bidId);
        _allBidIds.push(bidSequence);
        if (msg.value > bidWei) {
            (bool refund,) = msg.sender.call{value: msg.value - bidWei}("");
            if (!refund) revert MFX_TransferFailed();
        }
        emit BidPlaced(bidId, stemId, msg.sender, bidWei, block.number, expiry);
        return bidId;
    }

    function placeBidWithExpiry(bytes32 stemId, uint256 bidWei, uint256 expiryBlock) external payable whenNotPaused nonReentrant returns (bytes32 bidId) {
        if (expiryBlock <= block.number) revert MFX_ExpiryPast();
        if (stems[stemId].lister == address(0)) revert MFX_StemNotFound();
        if (stems[stemId].filled || stems[stemId].delisted) revert MFX_StemNotFound();
        if (block.number >= stems[stemId].expiryBlock) revert MFX_ListingExpired();
        if (bidWei < minListingWei) revert MFX_BelowMinListing();
        if (bidWei > maxListingWei) revert MFX_AboveMaxListing();
        if (msg.value < bidWei) revert MFX_InsufficientValue();
        bytes32[] storage list = bidIdsByBidder[msg.sender];
        if (list.length >= MFX_MAX_BIDS_PER_USER) revert MFX_MaxBidsReached();

        bidSequence++;
        bidId = _bidId(stemId, msg.sender, bidWei, bidSequence);
        if (bids[bidId].bidder != address(0)) revert MFX_BidNotFound();

        bids[bidId] = BidRecord({
            stemId: stemId,
            bidder: msg.sender,
            bidWei: bidWei,
            placedAtBlock: block.number,
            expiryBlock: expiryBlock,
            filled: false,
            cancelled: false
        });
        bidIdIndexInBidderList[bidId] = list.length;
        list.push(bidId);
        bidCountForStem[stemId]++;
        bidIdsForStem[stemId].push(bidId);
        _allBidIds.push(bidSequence);
        if (msg.value > bidWei) {
            (bool refund,) = msg.sender.call{value: msg.value - bidWei}("");
            if (!refund) revert MFX_TransferFailed();
        }
        emit BidPlaced(bidId, stemId, msg.sender, bidWei, block.number, expiryBlock);
        return bidId;
    }

    function cancelBid(bytes32 bidId) external whenNotPaused nonReentrant {
        BidRecord storage b = bids[bidId];
        if (b.bidder != msg.sender) revert MFX_NotBidder();
        if (b.filled) revert MFX_AlreadyFilled();
        if (b.cancelled) revert MFX_AlreadyCancelled();
        b.cancelled = true;
        (bool sent,) = msg.sender.call{value: b.bidWei}("");
        if (!sent) revert MFX_TransferFailed();
        emit BidCancelled(bidId, msg.sender, block.number);
    }

    function updateBidAmount(bytes32 bidId, uint256 newBidWei) external payable whenNotPaused nonReentrant {
        BidRecord storage b = bids[bidId];
        if (b.bidder != msg.sender) revert MFX_NotBidder();
        if (b.filled || b.cancelled) revert MFX_BidNotFound();
        if (block.number >= b.expiryBlock) revert MFX_BidExpired();
        if (newBidWei < minListingWei || newBidWei > maxListingWei) revert MFX_BidMismatch();
        uint256 prevWei = b.bidWei;
        if (newBidWei > prevWei) {
            if (msg.value < newBidWei - prevWei) revert MFX_InsufficientValue();
            b.bidWei = newBidWei;
            if (msg.value > newBidWei - prevWei) {
                (bool refund,) = msg.sender.call{value: msg.value - (newBidWei - prevWei)}("");
                if (!refund) revert MFX_TransferFailed();
            }
        } else if (newBidWei < prevWei) {
            b.bidWei = newBidWei;
            (bool sent,) = msg.sender.call{value: prevWei - newBidWei}("");
            if (!sent) revert MFX_TransferFailed();
        }
        emit BidAmountUpdated(bidId, prevWei, b.bidWei, block.number);
    }

    function batchCancelBids(bytes32[] calldata bidIds) external whenNotPaused nonReentrant {
        if (bidIds.length > MFX_MAX_BATCH_SIZE) revert MFX_BatchTooLarge();
        for (uint256 i = 0; i < bidIds.length; i++) {
            BidRecord storage b = bids[bidIds[i]];
            if (b.bidder == msg.sender && !b.filled && !b.cancelled) {
                b.cancelled = true;
                (bool sent,) = msg.sender.call{value: b.bidWei}("");
                if (!sent) revert MFX_TransferFailed();
                emit BidCancelled(bidIds[i], msg.sender, block.number);
            }
        }
        emit BatchBidsCancelled(bidIds, msg.sender, block.number);
    }

    function fillStemOffer(bytes32 stemId) external payable whenNotPaused nonReentrant {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0)) revert MFX_StemNotFound();
        if (s.filled || s.delisted) revert MFX_AlreadyFilled();
        if (block.number >= s.expiryBlock) revert MFX_ListingExpired();
        if (msg.value != s.askWei) revert MFX_AskMismatch();

        uint256 feeWei = (msg.value * feeBps) / MFX_BPS_DENOM;
        uint256 halfFee = feeWei / 2;
        _feeTreasuryAccum += halfFee;
        _feeVaultAccum += (feeWei - halfFee);
        uint256 toLister = msg.value - feeWei;

        s.filled = true;
        stemVolumeWei[stemId] += msg.value;
        listerVolumeWei[s.lister] += toLister;
        totalVolumeWei += msg.value;
        totalFeesWei += feeWei;
        (bool toListerOk,) = s.lister.call{value: toLister}("");
        if (!toListerOk) revert MFX_TransferFailed();
        emit OfferFilled(stemId, msg.sender, s.lister, msg.value, feeWei, block.number);
    }

    function fillBid(bytes32 bidId) external payable whenNotPaused nonReentrant {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0)) revert MFX_BidNotFound();
        if (b.filled || b.cancelled) revert MFX_AlreadyFilled();
        if (block.number >= b.expiryBlock) revert MFX_BidExpired();
        StemListing storage s = stems[b.stemId];
        if (s.lister != msg.sender) revert MFX_NotLister();
        if (s.filled || s.delisted) revert MFX_StemNotFound();
        if (block.number >= s.expiryBlock) revert MFX_ListingExpired();

        uint256 feeWei = (b.bidWei * feeBps) / MFX_BPS_DENOM;
        uint256 halfFee = feeWei / 2;
        _feeTreasuryAccum += halfFee;
        _feeVaultAccum += (feeWei - halfFee);
        uint256 toSeller = b.bidWei - feeWei;

        b.filled = true;
        s.filled = true;
        stemVolumeWei[b.stemId] += b.bidWei;
        listerVolumeWei[msg.sender] += toSeller;
        bidderVolumeWei[b.bidder] += b.bidWei;
        totalVolumeWei += b.bidWei;
        totalFeesWei += feeWei;
        (bool toSellerOk,) = msg.sender.call{value: toSeller}("");
        if (!toSellerOk) revert MFX_TransferFailed();
        emit BidFilled(bidId, b.stemId, msg.sender, b.bidder, toSeller, feeWei, block.number);
    }

    function sendCollabInvite(bytes32 stemId, address invitee, uint256 shareBps) external whenNotPaused nonReentrant returns (bytes32 collabId) {
        if (invitee == address(0)) revert MFX_ZeroAddress();
        if (shareBps == 0 || shareBps > MFX_BPS_DENOM) revert MFX_InvalidShareBps();
        StemListing storage s = stems[stemId];
        if (s.lister != msg.sender) revert MFX_NotLister();
        if (s.filled || s.delisted) revert MFX_StemNotFound();

        collabSequence++;
        collabId = _collabId(stemId, msg.sender, invitee, collabSequence);
        if (collabs[collabId].inviter != address(0)) revert MFX_CollabNotFound();

        collabs[collabId] = CollabInvite({
            stemId: stemId,
            inviter: msg.sender,
            invitee: invitee,
            shareBps: shareBps,
            sentAtBlock: block.number,
            accepted: false,
            rejected: false
        });
        collabInvitesSent[msg.sender]++;
        collabInvitesReceived[invitee]++;
        emit CollabInviteSent(collabId, stemId, msg.sender, invitee, shareBps, block.number);
        return collabId;
    }

    function acceptCollab(bytes32 collabId) external whenNotPaused {
        CollabInvite storage c = collabs[collabId];
        if (c.invitee != msg.sender) revert MFX_NotInvitee();
        if (c.accepted || c.rejected) revert MFX_CollabAlreadyResponded();
        c.accepted = true;
        collabParticipants[c.stemId].push(msg.sender);
        emit CollabAccepted(collabId, msg.sender, block.number);
    }

    function rejectCollab(bytes32 collabId) external whenNotPaused {
        CollabInvite storage c = collabs[collabId];
        if (c.invitee != msg.sender) revert MFX_NotInvitee();
        if (c.accepted || c.rejected) revert MFX_CollabAlreadyResponded();
        c.rejected = true;
        emit CollabRejected(collabId, msg.sender, block.number);
    }

    function distributeRoyalty(bytes32 stemId, address[] calldata recipients, uint256[] calldata amountsWei) external whenNotPaused nonReentrant {
        if (recipients.length != amountsWei.length) revert MFX_ArrayLengthMismatch();
        StemListing storage s = stems[stemId];
        if (s.lister != msg.sender) revert MFX_NotLister();
        uint256 total = 0;
        for (uint256 i = 0; i < amountsWei.length; i++) {
            total += amountsWei[i];
        }
        if (address(this).balance < total) revert MFX_InsufficientValue();
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert MFX_ZeroAddress();
            if (amountsWei[i] == 0) continue;
            totalRoyaltyPaid[stemId] += amountsWei[i];
            (bool sent,) = recipients[i].call{value: amountsWei[i]}("");
            if (!sent) revert MFX_TransferFailed();
            emit RoyaltySplit(stemId, recipients[i], amountsWei[i], MFX_SPLIT_ROYALTY, block.number);
        }
    }

    function sweepTreasuryFees() external nonReentrant {
        if (msg.sender != treasury) revert MFX_NotKeeper();
        uint256 amount = _feeTreasuryAccum;
        if (amount == 0) revert MFX_ZeroAmount();
        _feeTreasuryAccum = 0;
        (bool sent,) = treasury.call{value: amount}("");
        if (!sent) revert MFX_TransferFailed();
        emit FeeSwept(treasury, amount, MFX_VAULT_TREASURY, block.number);
    }

    function sweepVaultFees() external nonReentrant {
        if (msg.sender != feeVault) revert MFX_NotKeeper();
        uint256 amount = _feeVaultAccum;
        if (amount == 0) revert MFX_ZeroAmount();
        _feeVaultAccum = 0;
        (bool sent,) = feeVault.call{value: amount}("");
        if (!sent) revert MFX_TransferFailed();
        emit FeeSwept(feeVault, amount, MFX_VAULT_FEE, block.number);
    }

    function keeperDelistExpiredStem(bytes32 stemId) external nonReentrant {
        if (msg.sender != keeper) revert MFX_NotKeeper();
        StemListing storage s = stems[stemId];
        if (s.lister == address(0)) revert MFX_StemNotFound();
        if (s.filled || s.delisted) revert MFX_StemNotFound();
        if (block.number < s.expiryBlock) revert MFX_ListingExpired();
        s.delisted = true;
        emit StemDelisted(stemId, s.lister, block.number);
    }

    function getStem(bytes32 stemId) external view returns (
        address lister,
        bytes32 contentHash,
        uint256 askWei,
        uint256 listedAtBlock,
        uint256 expiryBlock,
        bool filled,
        bool delisted
    ) {
        StemListing storage s = stems[stemId];
        return (s.lister, s.contentHash, s.askWei, s.listedAtBlock, s.expiryBlock, s.filled, s.delisted);
    }

    function getBid(bytes32 bidId) external view returns (
        bytes32 stemId,
        address bidder,
        uint256 bidWei,
        uint256 placedAtBlock,
        uint256 expiryBlock,
        bool filled,
        bool cancelled
    ) {
        BidRecord storage b = bids[bidId];
        return (b.stemId, b.bidder, b.bidWei, b.placedAtBlock, b.expiryBlock, b.filled, b.cancelled);
    }

    function getCollab(bytes32 collabId) external view returns (
        bytes32 stemId,
        address inviter,
        address invitee,
        uint256 shareBps,
        uint256 sentAtBlock,
        bool accepted,
        bool rejected
    ) {
        CollabInvite storage c = collabs[collabId];
        return (c.stemId, c.inviter, c.invitee, c.shareBps, c.sentAtBlock, c.accepted, c.rejected);
    }

    function getStemIdsByLister(address lister) external view returns (bytes32[] memory) {
        return stemIdsByLister[lister];
    }

    function getBidIdsByBidder(address bidder) external view returns (bytes32[] memory) {
        return bidIdsByBidder[bidder];
    }

    function getCollabParticipants(bytes32 stemId) external view returns (address[] memory) {
        return collabParticipants[stemId];
    }

    function getFeeTreasuryAccum() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function getFeeVaultAccum() external view returns (uint256) {
        return _feeVaultAccum;
    }

    function getTotalRoyaltyPaid(bytes32 stemId) external view returns (uint256) {
        return totalRoyaltyPaid[stemId];
    }

    function getConfig() external view returns (
        address _treasury,
        address _feeVault,
        address _exchangeKeeper,
        address _keeper,
        uint256 _feeBps,
        uint256 _minListingWei,
        uint256 _maxListingWei,
        uint256 _defaultExpiryBlocks,
        uint256 _deployedBlock,
        bool _exchangePaused
    ) {
        return (
            treasury,
            feeVault,
            exchangeKeeper,
            keeper,
            feeBps,
            minListingWei,
            maxListingWei,
            defaultExpiryBlocks,
            deployedBlock,
            exchangePaused
        );
    }

    function canFillStem(bytes32 stemId) external view returns (bool) {
        StemListing storage s = stems[stemId];
        return s.lister != address(0) && !s.filled && !s.delisted && block.number < s.expiryBlock;
    }

    function canFillBid(bytes32 bidId) external view returns (bool) {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0) || b.filled || b.cancelled || block.number >= b.expiryBlock) return false;
        StemListing storage s = stems[b.stemId];
        return s.lister != address(0) && !s.filled && !s.delisted && block.number < s.expiryBlock;
    }

    function computeStemId(bytes32 contentHash, address lister, uint256 seq) external pure returns (bytes32) {
        return _stemId(contentHash, lister, seq);
    }

    function computeBidId(bytes32 stemId, address bidder, uint256 bidWei, uint256 seq) external pure returns (bytes32) {
        return _bidId(stemId, bidder, bidWei, seq);
    }

    function computeCollabId(bytes32 stemId, address inviter, address invitee, uint256 seq) external pure returns (bytes32) {
        return _collabId(stemId, inviter, invitee, seq);
    }

    function getBidIdsForStem(bytes32 stemId) external view returns (bytes32[] memory) {
        return bidIdsForStem[stemId];
    }

    function keeperBatchDelistExpiredStems(bytes32[] calldata stemIds) external nonReentrant {
        if (msg.sender != keeper) revert MFX_NotKeeper();
        if (stemIds.length > MFX_MAX_BATCH_SIZE) revert MFX_BatchTooLarge();
        for (uint256 i = 0; i < stemIds.length; i++) {
            StemListing storage s = stems[stemIds[i]];
            if (s.lister != address(0) && !s.filled && !s.delisted && block.number >= s.expiryBlock) {
                s.delisted = true;
                emit StemDelisted(stemIds[i], s.lister, block.number);
            }
        }
    }

    function getStemWithVolume(bytes32 stemId) external view returns (
        address lister,
        bytes32 contentHash,
        uint256 askWei,
        uint256 listedAtBlock,
        uint256 expiryBlock,
        bool filled,
        bool delisted,
        uint256 volumeWei
    ) {
        StemListing storage s = stems[stemId];
        return (
            s.lister,
            s.contentHash,
            s.askWei,
            s.listedAtBlock,
            s.expiryBlock,
            s.filled,
            s.delisted,
            stemVolumeWei[stemId]
        );
    }

    function getBidWithStemInfo(bytes32 bidId) external view returns (
        bytes32 stemId,
        address bidder,
        uint256 bidWei,
        uint256 placedAtBlock,
        uint256 expiryBlock,
        bool filled,
        bool cancelled,
        address stemLister,
        uint256 stemAskWei
    ) {
        BidRecord storage b = bids[bidId];
        StemListing storage s = stems[b.stemId];
        return (
            b.stemId,
            b.bidder,
            b.bidWei,
            b.placedAtBlock,
            b.expiryBlock,
            b.filled,
            b.cancelled,
            s.lister,
            s.askWei
        );
    }

    function getListerStats(address lister) external view returns (
        uint256 listingCount,
        uint256 totalVolumeWei,
        uint256 collabInvitesSentCount
    ) {
        return (
            stemIdsByLister[lister].length,
            listerVolumeWei[lister],
            collabInvitesSent[lister]
        );
    }

    function getBidderStats(address bidder) external view returns (
        uint256 bidCount,
        uint256 totalVolumeWei,
        uint256 collabInvitesReceivedCount
    ) {
        return (
            bidIdsByBidder[bidder].length,
            bidderVolumeWei[bidder],
            collabInvitesReceived[bidder]
        );
    }

    function getExchangeStats() external view returns (
        uint256 totalStemsListed,
        uint256 totalBidsPlaced,
        uint256 totalVolume,
        uint256 totalFees,
        uint256 treasuryAccum,
        uint256 vaultAccum
    ) {
        return (
            stemSequence,
            bidSequence,
            totalVolumeWei,
            totalFeesWei,
            _feeTreasuryAccum,
            _feeVaultAccum
        );
    }

    function blocksUntilStemExpiry(bytes32 stemId) external view returns (uint256) {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0) || s.filled || s.delisted) return 0;
        if (block.number >= s.expiryBlock) return 0;
        return s.expiryBlock - block.number;
    }

    function blocksUntilBidExpiry(bytes32 bidId) external view returns (uint256) {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0) || b.filled || b.cancelled) return 0;
        if (block.number >= b.expiryBlock) return 0;
        return b.expiryBlock - block.number;
    }

    function getFeeForAmount(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / MFX_BPS_DENOM;
    }

    function getNetAfterFee(uint256 amountWei) external view returns (uint256) {
        return amountWei - (amountWei * feeBps) / MFX_BPS_DENOM;
    }

    function getMultipleStems(bytes32[] calldata stemIds) external view returns (
        address[] memory listers,
        bytes32[] memory contentHashes,
        uint256[] memory askWeis,
        uint256[] memory listedAtBlocks,
        uint256[] memory expiryBlocks,
        bool[] memory filleds,
        bool[] memory delisteds
    ) {
        uint256 n = stemIds.length;
        listers = new address[](n);
        contentHashes = new bytes32[](n);
        askWeis = new uint256[](n);
        listedAtBlocks = new uint256[](n);
        expiryBlocks = new uint256[](n);
        filleds = new bool[](n);
        delisteds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            StemListing storage s = stems[stemIds[i]];
            listers[i] = s.lister;
            contentHashes[i] = s.contentHash;
            askWeis[i] = s.askWei;
            listedAtBlocks[i] = s.listedAtBlock;
            expiryBlocks[i] = s.expiryBlock;
            filleds[i] = s.filled;
            delisteds[i] = s.delisted;
        }
    }

    function getMultipleBids(bytes32[] calldata bidIds) external view returns (
        bytes32[] memory stemIdsOut,
        address[] memory bidders,
        uint256[] memory bidWeis,
        uint256[] memory placedAtBlocks,
        uint256[] memory expiryBlocks,
        bool[] memory filleds,
        bool[] memory cancelleds
    ) {
        uint256 n = bidIds.length;
        stemIdsOut = new bytes32[](n);
        bidders = new address[](n);
        bidWeis = new uint256[](n);
        placedAtBlocks = new uint256[](n);
        expiryBlocks = new uint256[](n);
        filleds = new bool[](n);
        cancelleds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            BidRecord storage b = bids[bidIds[i]];
            stemIdsOut[i] = b.stemId;
            bidders[i] = b.bidder;
            bidWeis[i] = b.bidWei;
            placedAtBlocks[i] = b.placedAtBlock;
            expiryBlocks[i] = b.expiryBlock;
            filleds[i] = b.filled;
            cancelleds[i] = b.cancelled;
        }
    }

    function getActiveStemIdsForLister(address lister) external view returns (bytes32[] memory) {
        bytes32[] storage all = stemIdsByLister[lister];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            StemListing storage s = stems[all[i]];
            if (!s.filled && !s.delisted && block.number < s.expiryBlock) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            StemListing storage s = stems[all[i]];
            if (!s.filled && !s.delisted && block.number < s.expiryBlock) out[count++] = all[i];
        }
        return out;
    }

    function getActiveBidIdsForBidder(address bidder) external view returns (bytes32[] memory) {
        bytes32[] storage all = bidIdsByBidder[bidder];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock) out[count++] = all[i];
        }
        return out;
    }

    function getExpiredStemIdsForLister(address lister) external view returns (bytes32[] memory) {
        bytes32[] storage all = stemIdsByLister[lister];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            StemListing storage s = stems[all[i]];
            if (!s.filled && !s.delisted && block.number >= s.expiryBlock) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            StemListing storage s = stems[all[i]];
            if (!s.filled && !s.delisted && block.number >= s.expiryBlock) out[count++] = all[i];
        }
        return out;
    }

    function getExpiredBidIdsForBidder(address bidder) external view returns (bytes32[] memory) {
        bytes32[] storage all = bidIdsByBidder[bidder];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number >= b.expiryBlock) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number >= b.expiryBlock) out[count++] = all[i];
        }
        return out;
    }

    function getActiveBidIdsForStem(bytes32 stemId) external view returns (bytes32[] memory) {
        bytes32[] storage all = bidIdsForStem[stemId];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock) count++;
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock) out[count++] = all[i];
        }
        return out;
    }

    function getHighestBidForStem(bytes32 stemId) external view returns (bytes32 bidId, uint256 bidWei) {
        bytes32[] storage all = bidIdsForStem[stemId];
        bidWei = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock && b.bidWei > bidWei) {
                bidWei = b.bidWei;
                bidId = all[i];
            }
        }
    }

    function getStemCountForLister(address lister) external view returns (uint256) {
        return stemIdsByLister[lister].length;
    }

    function getBidCountForBidder(address bidder) external view returns (uint256) {
        return bidIdsByBidder[bidder].length;
    }

    function getListerStemAt(address lister, uint256 index) external view returns (bytes32) {
        return stemIdsByLister[lister][index];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getDomainHash() external view returns (bytes32) {
        return exchangeDomain;
    }

    function isStemActive(bytes32 stemId) external view returns (bool) {
        StemListing storage s = stems[stemId];
        return s.lister != address(0) && !s.filled && !s.delisted && block.number < s.expiryBlock;
    }

    function isBidActive(bytes32 bidId) external view returns (bool) {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0) || b.filled || b.cancelled || block.number >= b.expiryBlock) return false;
        StemListing storage s = stems[b.stemId];
        return s.lister != address(0) && !s.filled && !s.delisted && block.number < s.expiryBlock;
    }

    function getCollabCountForStem(bytes32 stemId) external view returns (uint256) {
        return collabParticipants[stemId].length;
    }

    function getCollabParticipantAt(bytes32 stemId, uint256 index) external view returns (address) {
        return collabParticipants[stemId][index];
    }

    function getNextStemSequence() external view returns (uint256) {
        return stemSequence + 1;
    }

    function getNextBidSequence() external view returns (uint256) {
        return bidSequence + 1;
    }

    function getNextCollabSequence() external view returns (uint256) {
        return collabSequence + 1;
    }

    function validateStemListingParams(bytes32 contentHash, uint256 askWei) external view returns (bool ok) {
        if (contentHash == bytes32(0)) return false;
        if (askWei < minListingWei) return false;
        if (askWei > maxListingWei) return false;
        if (stemIdsByLister[msg.sender].length >= MFX_MAX_LISTINGS_PER_USER) return false;
        return true;
    }

    function validateBidParams(bytes32 stemId, uint256 bidWei) external view returns (bool ok) {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0)) return false;
        if (s.filled || s.delisted) return false;
        if (block.number >= s.expiryBlock) return false;
        if (bidWei < minListingWei) return false;
        if (bidWei > maxListingWei) return false;
        if (bidIdsByBidder[msg.sender].length >= MFX_MAX_BIDS_PER_USER) return false;
        return true;
    }

    function estimateListerReceive(uint256 askWei) external view returns (uint256 netWei, uint256 feeWei) {
        feeWei = (askWei * feeBps) / MFX_BPS_DENOM;
        netWei = askWei - feeWei;
    }

    function estimateBidderReceive(uint256 bidWei) external view returns (uint256 netWei, uint256 feeWei) {
        feeWei = (bidWei * feeBps) / MFX_BPS_DENOM;
        netWei = bidWei - feeWei;
    }

    function getConstants() external pure returns (
        uint256 bpsDenom,
        uint256 maxFeeBps,
        uint256 maxListingsPerUser,
        uint256 maxBidsPerUser,
        uint256 maxBatchSize,
        uint256 minExpiryBlocks,
        uint256 maxExpiryBlocks
    ) {
        return (
            MFX_BPS_DENOM,
            MFX_MAX_FEE_BPS,
            MFX_MAX_LISTINGS_PER_USER,
            MFX_MAX_BIDS_PER_USER,
            MFX_MAX_BATCH_SIZE,
            MFX_MIN_EXPIRY_BLOCKS,
            MFX_MAX_EXPIRY_BLOCKS
        );
    }

    function getFullStemInfo(bytes32 stemId) external view returns (
        address lister,
        bytes32 contentHash,
        uint256 askWei,
        uint256 listedAtBlock,
        uint256 expiryBlock,
        bool filled,
        bool delisted,
        uint256 volumeWei,
        uint256 royaltyPaid,
        uint256 bidCount,
        uint256 collabParticipantCount
    ) {
        StemListing storage s = stems[stemId];
        return (
            s.lister,
            s.contentHash,
            s.askWei,
            s.listedAtBlock,
            s.expiryBlock,
            s.filled,
            s.delisted,
            stemVolumeWei[stemId],
            totalRoyaltyPaid[stemId],
            bidIdsForStem[stemId].length,
            collabParticipants[stemId].length
        );
    }

    function getFullBidInfo(bytes32 bidId) external view returns (
        bytes32 stemId,
        address bidder,
        uint256 bidWei,
        uint256 placedAtBlock,
        uint256 expiryBlock,
        bool filled,
        bool cancelled,
        address stemLister,
        uint256 stemAskWei,
        bool stemFilled,
        bool stemDelisted
    ) {
        BidRecord storage b = bids[bidId];
        StemListing storage s = stems[b.stemId];
        return (
            b.stemId,
            b.bidder,
            b.bidWei,
            b.placedAtBlock,
            b.expiryBlock,
            b.filled,
            b.cancelled,
            s.lister,
            s.askWei,
            s.filled,
            s.delisted
        );
    }

    function getFullCollabInfo(bytes32 collabId) external view returns (
        bytes32 stemId,
        address inviter,
        address invitee,
        uint256 shareBps,
        uint256 sentAtBlock,
        bool accepted,
        bool rejected,
        address stemLister,
        uint256 stemAskWei
    ) {
        CollabInvite storage c = collabs[collabId];
        StemListing storage s = stems[c.stemId];
        return (
            c.stemId,
            c.inviter,
            c.invitee,
            c.shareBps,
            c.sentAtBlock,
            c.accepted,
            c.rejected,
            s.lister,
            s.askWei
        );
    }

    function getListerVolumeRank(address[] calldata listers) external view returns (uint256[] memory volumes, uint256[] memory ranks) {
        uint256 n = listers.length;
        volumes = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            volumes[i] = listerVolumeWei[listers[i]];
        }
        ranks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = 1;
            for (uint256 j = 0; j < n; j++) {
                if (listerVolumeWei[listers[j]] > volumes[i]) r++;
            }
            ranks[i] = r;
        }
    }

    function getBidderVolumeRank(address[] calldata bidders) external view returns (uint256[] memory volumes, uint256[] memory ranks) {
        uint256 n = bidders.length;
        volumes = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            volumes[i] = bidderVolumeWei[bidders[i]];
        }
        ranks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = 1;
            for (uint256 j = 0; j < n; j++) {
                if (bidderVolumeWei[bidders[j]] > volumes[i]) r++;
            }
            ranks[i] = r;
        }
    }

    function getStemsByListerPaginated(address lister, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory stemIdsOut,
        uint256 totalCount
    ) {
        bytes32[] storage all = stemIdsByLister[lister];
        totalCount = all.length;
        if (offset >= totalCount) {
            stemIdsOut = new bytes32[](0);
            return (stemIdsOut, totalCount);
        }
        uint256 end = offset + limit;
        if (end > totalCount) end = totalCount;
        uint256 resultLen = end - offset;
        stemIdsOut = new bytes32[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            stemIdsOut[i] = all[offset + i];
        }
    }

    function getBidsByBidderPaginated(address bidder, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory bidIdsOut,
        uint256 totalCount
    ) {
        bytes32[] storage all = bidIdsByBidder[bidder];
        totalCount = all.length;
        if (offset >= totalCount) {
            bidIdsOut = new bytes32[](0);
            return (bidIdsOut, totalCount);
        }
        uint256 end = offset + limit;
        if (end > totalCount) end = totalCount;
        uint256 resultLen = end - offset;
        bidIdsOut = new bytes32[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            bidIdsOut[i] = all[offset + i];
        }
    }

    function getBidsByStemPaginated(bytes32 stemId, uint256 offset, uint256 limit) external view returns (
        bytes32[] memory bidIdsOut,
        uint256 totalCount
    ) {
        bytes32[] storage all = bidIdsForStem[stemId];
        totalCount = all.length;
        if (offset >= totalCount) {
            bidIdsOut = new bytes32[](0);
            return (bidIdsOut, totalCount);
        }
        uint256 end = offset + limit;
        if (end > totalCount) end = totalCount;
        uint256 resultLen = end - offset;
        bidIdsOut = new bytes32[](resultLen);
        for (uint256 i = 0; i < resultLen; i++) {
            bidIdsOut[i] = all[offset + i];
        }
    }

    function getDeployedBlock() external view returns (uint256) {
        return deployedBlock;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function getStemAskWei(bytes32 stemId) external view returns (uint256) {
        return stems[stemId].askWei;
    }

    function getStemLister(bytes32 stemId) external view returns (address) {
        return stems[stemId].lister;
    }

    function getStemContentHash(bytes32 stemId) external view returns (bytes32) {
        return stems[stemId].contentHash;
    }

    function getStemExpiryBlock(bytes32 stemId) external view returns (uint256) {
        return stems[stemId].expiryBlock;
    }

    function getBidStemId(bytes32 bidId) external view returns (bytes32) {
        return bids[bidId].stemId;
    }

    function getBidBidder(bytes32 bidId) external view returns (address) {
        return bids[bidId].bidder;
    }

    function getBidWei(bytes32 bidId) external view returns (uint256) {
        return bids[bidId].bidWei;
    }

    function getBidExpiryBlock(bytes32 bidId) external view returns (uint256) {
        return bids[bidId].expiryBlock;
    }

    function getTreasuryAddress() external view returns (address) {
        return treasury;
    }

    function getFeeVaultAddress() external view returns (address) {
        return feeVault;
    }

    function getExchangeKeeperAddress() external view returns (address) {
        return exchangeKeeper;
    }

    function getKeeperAddress() external view returns (address) {
        return keeper;
    }

    function getCurrentBlock() external view returns (uint256) {
        return block.number;
    }

    function getFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function getMinListingWei() external view returns (uint256) {
        return minListingWei;
    }

    function getMaxListingWei() external view returns (uint256) {
        return maxListingWei;
    }

    function getDefaultExpiryBlocks() external view returns (uint256) {
        return defaultExpiryBlocks;
    }

    function isExchangePaused() external view returns (bool) {
        return exchangePaused;
    }

    function getStemSequence() external view returns (uint256) {
        return stemSequence;
    }

    function getBidSequence() external view returns (uint256) {
        return bidSequence;
    }

    function getCollabSequence() external view returns (uint256) {
        return collabSequence;
    }

    function hasStemExpired(bytes32 stemId) external view returns (bool) {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0)) return true;
        return block.number >= s.expiryBlock;
    }

    function hasBidExpired(bytes32 bidId) external view returns (bool) {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0)) return true;
        return block.number >= b.expiryBlock;
    }

    function getStemStatus(bytes32 stemId) external view returns (uint8 status) {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0)) return 0;
        if (s.filled) return 1;
        if (s.delisted) return 2;
        if (block.number >= s.expiryBlock) return 3;
        return 4;
    }

    function getBidStatus(bytes32 bidId) external view returns (uint8 status) {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0)) return 0;
        if (b.filled) return 1;
        if (b.cancelled) return 2;
        if (block.number >= b.expiryBlock) return 3;
        return 4;
    }

    function getStemIdsForListerRange(address lister, uint256 fromIdx, uint256 toIdx) external view returns (bytes32[] memory out) {
        bytes32[] storage all = stemIdsByLister[lister];
        if (toIdx > all.length) toIdx = all.length;
        if (fromIdx >= toIdx) return new bytes32[](0);
        uint256 n = toIdx - fromIdx;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = all[fromIdx + i];
        }
    }

    function getBidIdsForBidderRange(address bidder, uint256 fromIdx, uint256 toIdx) external view returns (bytes32[] memory out) {
        bytes32[] storage all = bidIdsByBidder[bidder];
        if (toIdx > all.length) toIdx = all.length;
        if (fromIdx >= toIdx) return new bytes32[](0);
        uint256 n = toIdx - fromIdx;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = all[fromIdx + i];
        }
    }

    function getBidIdsForStemRange(bytes32 stemId, uint256 fromIdx, uint256 toIdx) external view returns (bytes32[] memory out) {
        bytes32[] storage all = bidIdsForStem[stemId];
        if (toIdx > all.length) toIdx = all.length;
        if (fromIdx >= toIdx) return new bytes32[](0);
        uint256 n = toIdx - fromIdx;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = all[fromIdx + i];
        }
    }

    function computeFeeWei(uint256 amountWei) external view returns (uint256) {
        return (amountWei * feeBps) / MFX_BPS_DENOM;
    }

    function computeNetWei(uint256 amountWei) external view returns (uint256) {
        uint256 fee = (amountWei * feeBps) / MFX_BPS_DENOM;
        return amountWei - fee;
    }

    function wouldAcceptAsk(bytes32 stemId, uint256 sentWei) external view returns (bool) {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0) || s.filled || s.delisted || block.number >= s.expiryBlock) return false;
        return sentWei == s.askWei;
    }

    function wouldAcceptBid(bytes32 bidId, address seller) external view returns (bool) {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0) || b.filled || b.cancelled || block.number >= b.expiryBlock) return false;
        StemListing storage s = stems[b.stemId];
        return s.lister == seller && !s.filled && !s.delisted && block.number < s.expiryBlock;
    }

    function getTotalStemsEverListed() external view returns (uint256) {
        return stemSequence;
    }

    function getListerActiveCount(address lister) external view returns (uint256) {
        bytes32[] storage all = stemIdsByLister[lister];
        uint256 c = 0;
        for (uint256 i = 0; i < all.length; i++) {
            StemListing storage s = stems[all[i]];
            if (!s.filled && !s.delisted && block.number < s.expiryBlock) c++;
        }
        return c;
    }

    function getBidderActiveCount(address bidder) external view returns (uint256) {
        bytes32[] storage all = bidIdsByBidder[bidder];
        uint256 c = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock) c++;
        }
        return c;
    }

    function getStemActiveBidCount(bytes32 stemId) external view returns (uint256) {
        bytes32[] storage all = bidIdsForStem[stemId];
        uint256 c = 0;
        for (uint256 i = 0; i < all.length; i++) {
            BidRecord storage b = bids[all[i]];
            if (!b.filled && !b.cancelled && block.number < b.expiryBlock) c++;
        }
        return c;
    }

    function getSalt() external pure returns (uint256) {
        return MFX_EXCHANGE_SALT;
    }

    function getDomainName() external pure returns (bytes32) {
        return keccak256("MixFinex");
    }

    function getVaultKindTreasury() external pure returns (uint8) {
        return MFX_VAULT_TREASURY;
    }

    function getVaultKindFee() external pure returns (uint8) {
        return MFX_VAULT_FEE;
    }

    function getSplitKindCollab() external pure returns (uint8) {
        return MFX_SPLIT_COLLAB;
    }

    function getSplitKindRoyalty() external pure returns (uint8) {
        return MFX_SPLIT_ROYALTY;
    }

    function getExchangeDomainPacked() external view returns (bytes32) {
        return keccak256(abi.encodePacked("MixFinex_", block.chainid, block.prevrandao, MFX_EXCHANGE_SALT));
    }

    function _requireStemActive(bytes32 stemId) internal view {
        StemListing storage s = stems[stemId];
        if (s.lister == address(0)) revert MFX_StemNotFound();
        if (s.filled || s.delisted) revert MFX_AlreadyFilled();
        if (block.number >= s.expiryBlock) revert MFX_ListingExpired();
    }

    function _requireBidActive(bytes32 bidId) internal view {
        BidRecord storage b = bids[bidId];
        if (b.bidder == address(0)) revert MFX_BidNotFound();
        if (b.filled || b.cancelled) revert MFX_AlreadyFilled();
        if (block.number >= b.expiryBlock) revert MFX_BidExpired();
    }

    function getStemListedBlock(bytes32 stemId) external view returns (uint256) {
        return stems[stemId].listedAtBlock;
    }

    function getBidPlacedBlock(bytes32 bidId) external view returns (uint256) {
        return bids[bidId].placedAtBlock;
    }

    function getCollabSentBlock(bytes32 collabId) external view returns (uint256) {
        return collabs[collabId].sentAtBlock;
    }

    function isCollabAccepted(bytes32 collabId) external view returns (bool) {
        return collabs[collabId].accepted;
    }

    function isCollabRejected(bytes32 collabId) external view returns (bool) {
        return collabs[collabId].rejected;
    }

    function getCollabShareBps(bytes32 collabId) external view returns (uint256) {
        return collabs[collabId].shareBps;
    }

    function getCollabInviter(bytes32 collabId) external view returns (address) {
        return collabs[collabId].inviter;
    }

    function getCollabInvitee(bytes32 collabId) external view returns (address) {
        return collabs[collabId].invitee;
    }

    function getCollabStemId(bytes32 collabId) external view returns (bytes32) {
        return collabs[collabId].stemId;
    }

    function getStemVolume(bytes32 stemId) external view returns (uint256) {
        return stemVolumeWei[stemId];
    }

    function getListerVolume(address lister) external view returns (uint256) {
        return listerVolumeWei[lister];
    }

    function getBidderVolume(address bidder) external view returns (uint256) {
        return bidderVolumeWei[bidder];
    }

    function getTotalVolume() external view returns (uint256) {
        return totalVolumeWei;
    }

    function getTotalFees() external view returns (uint256) {
        return totalFeesWei;
    }

    function getTreasuryAccum() external view returns (uint256) {
        return _feeTreasuryAccum;
    }

    function getVaultAccum() external view returns (uint256) {
        return _feeVaultAccum;
    }

    function getRoyaltyPaidForStem(bytes32 stemId) external view returns (uint256) {
        return totalRoyaltyPaid[stemId];
    }

    function getCollabParticipantsCount(bytes32 stemId) external view returns (uint256) {
        return collabParticipants[stemId].length;
    }

    function getBidCountForStem(bytes32 stemId) external view returns (uint256) {
        return bidIdsForStem[stemId].length;
    }

    function getStemFilled(bytes32 stemId) external view returns (bool) {
        return stems[stemId].filled;
