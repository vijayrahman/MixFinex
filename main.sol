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
