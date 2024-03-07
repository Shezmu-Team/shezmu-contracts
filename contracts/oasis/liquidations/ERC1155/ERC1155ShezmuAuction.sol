// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155ReceiverUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';

import {RateLib} from '../../../utils/RateLib.sol';

contract ERC1155ShezmuAuction is
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC1155ReceiverUpgradeable
{
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
    using RateLib for RateLib.Rate;

    error InvalidAmount();
    error ZeroAddress();
    error Unauthorized();
    error InvalidBid(uint256 bidAmount);
    error InvalidAuction(uint256 index);

    event NewAuction(
        uint256 indexed auctionId,
        IERC1155Upgradeable indexed nft,
        uint256 indexed index,
        uint256 amount,
        uint256 startTime
    );
    event NewBid(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 bidValue
    );
    event AuctionCanceled(uint256 indexed auctionId);
    event AuctionFailed(uint256 indexed auctionId);
    event NFTClaimed(uint256 indexed auctionId);
    event ETHClaimed(uint256 indexed auctionId);
    event BidWithdrawn(
        uint256 indexed auctionId,
        address indexed account,
        uint256 bidValue
    );
    event BidTimeIncrementChanged(uint256 newTime, uint256 oldTime);
    event MinimumIncrementRateChanged(
        RateLib.Rate newIncrementRate,
        RateLib.Rate oldIncrementRate
    );
    event DurationChanged(uint256 newDuration, uint256 oldDuration);

    struct Auction {
        address creator;
        IERC1155Upgradeable nftAddress;
        uint256 nftIndex;
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        uint256 minBid;
        address highestBidOwner;
        bool ownerClaimed;
        mapping(address => uint256) bids;
    }

    bytes32 public constant WHITELISTED_ROLE = keccak256('WHITELISTED_ROLE');

    uint256 public auctionDuration;
    uint256 public bidTimeIncrement;
    uint256 public auctionsLength;

    RateLib.Rate public minIncrementRate;

    mapping(address => EnumerableSetUpgradeable.UintSet) internal userAuctions;
    mapping(uint256 => Auction) public auctions;

    function initialize(
        uint256 _auctionDuration,
        uint256 _bidTimeIncrement,
        RateLib.Rate memory _incrementRate
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        setAuctionDuration(_auctionDuration);
        setBidTimeIncrement(_bidTimeIncrement);
        setMinimumIncrementRate(_incrementRate);
    }

    /// @notice Allows whitelisted addresses to create a new auction in the next slot.
    /// @param _nft The address of the NFT to sell
    /// @param _idx The index of the NFT to sell
    /// @param _minBid The minimum bid value
    function newAuction(
        address _owner,
        IERC1155Upgradeable _nft,
        uint256 _idx,
        uint256 _amount,
        uint256 _minBid
    ) external returns (uint256) {
        uint256 _startTime = _getNextSlotStart();
        return
            _newAuction(
                _owner,
                _nft,
                _idx,
                _amount,
                _startTime,
                _startTime + auctionDuration,
                _minBid
            );
    }

    /// @notice Allows the admin to create a new auction
    /// @param _nft The address of the NFT to sell
    /// @param _idx The index of the NFT to sell
    /// @param _startTime The time at which the auction starts
    /// @param _endTime The time at which the auction ends
    /// @param _minBid The minimum bid value
    function newCustomAuction(
        address _owner,
        IERC1155Upgradeable _nft,
        uint256 _idx,
        uint256 _amount,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _minBid
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        return
            _newAuction(
                _owner,
                _nft,
                _idx,
                _amount,
                _startTime,
                _endTime,
                _minBid
            );
    }

    /// @notice Allows the admin to cancel an ongoing auction with no bids
    /// @param _auctionIndex The index of the auction to cancel
    /// @param _nftRecipient The address to send the auctioned NFT to
    function cancelAuction(
        uint256 _auctionIndex,
        address _nftRecipient
    ) external {
        if (_nftRecipient == address(0)) revert ZeroAddress();

        Auction storage auction = auctions[_auctionIndex];
        IERC1155Upgradeable _nft = auction.nftAddress;
        if (address(_nft) == address(0)) revert InvalidAuction(_auctionIndex);
        if (auction.creator != msg.sender) revert Unauthorized();
        if (auction.highestBidOwner != address(0)) revert Unauthorized();

        uint256 _nftIndex = auction.nftIndex;
        uint256 _amount = auction.amount;
        delete auctions[_auctionIndex];

        _nft.safeTransferFrom(
            address(this),
            _nftRecipient,
            _nftIndex,
            _amount,
            '0x'
        );

        emit AuctionCanceled(_auctionIndex);
    }

    /// @notice Allows users to bid on an auction. In case of multiple bids by the same user,
    /// the actual bid value is the sum of all bids.
    /// @param _auctionIndex The index of the auction to bid on
    function bid(uint256 _auctionIndex) public payable nonReentrant {
        Auction storage auction = auctions[_auctionIndex];
        uint256 _endTime = auction.endTime;

        if (
            auction.startTime > block.timestamp ||
            block.timestamp >= auction.endTime
        ) revert Unauthorized();

        uint256 _previousBid = auction.bids[msg.sender];
        uint256 _bidValue = msg.value + _previousBid;
        uint256 _currentMinBid = auction.bids[auction.highestBidOwner];
        _currentMinBid += minIncrementRate.calculate(_currentMinBid);

        if (_currentMinBid > _bidValue || auction.minBid > _bidValue)
            revert InvalidBid(_bidValue);

        auction.highestBidOwner = msg.sender;
        auction.bids[msg.sender] = _bidValue;

        if (_previousBid == 0)
            assert(userAuctions[msg.sender].add(_auctionIndex));

        uint256 _bidIncrement = bidTimeIncrement;
        if (_bidIncrement > _endTime - block.timestamp)
            auction.endTime = block.timestamp + _bidIncrement;

        emit NewBid(_auctionIndex, msg.sender, _bidValue);
    }

    /// @notice Allows the highest bidder to claim the NFT they bid on if the auction is already over.
    /// @param _auctionIndex The index of the auction to claim the NFT from
    function claimNFT(uint256 _auctionIndex) external nonReentrant {
        Auction storage auction = auctions[_auctionIndex];

        if (
            auction.highestBidOwner != msg.sender ||
            auction.endTime > block.timestamp ||
            !userAuctions[msg.sender].remove(_auctionIndex)
        ) revert Unauthorized();

        auction.nftAddress.safeTransferFrom(
            address(this),
            msg.sender,
            auction.nftIndex,
            auction.amount,
            '0x'
        );

        emit NFTClaimed(_auctionIndex);
    }

    /// @notice Allows bidders to withdraw their bid. Only works if `msg.sender` isn't the highest bidder.
    /// @param _auctionIndex The auction to claim the bid from.
    function withdrawBid(uint256 _auctionIndex) public nonReentrant {
        Auction storage auction = auctions[_auctionIndex];

        if (auction.highestBidOwner == msg.sender) revert Unauthorized();

        uint256 _bidAmount = auction.bids[msg.sender];
        if (_bidAmount == 0) revert Unauthorized();

        delete auction.bids[msg.sender];
        assert(userAuctions[msg.sender].remove(_auctionIndex));

        (bool _sent, ) = payable(msg.sender).call{value: _bidAmount}('');
        assert(_sent);

        emit BidWithdrawn(_auctionIndex, msg.sender, _bidAmount);
    }

    /// @notice Allows bidders to withdraw multiple bids. Only works if `msg.sender` isn't the highest bidder.
    /// @param _indexes The auctions to claim the bids from.
    function withdrawBids(uint256[] calldata _indexes) external {
        for (uint256 i; i < _indexes.length; i++) {
            withdrawBid(_indexes[i]);
        }
    }

    /// @return The list of active bids for an account.
    /// @param _account The address to check.
    function getActiveBids(
        address _account
    ) external view returns (uint256[] memory) {
        return userAuctions[_account].values();
    }

    /// @return The active bid of an account for an auction.
    /// @param _auctionIndex The auction to retrieve the bid from.
    /// @param _account The bidder's account
    function getAuctionBid(
        uint256 _auctionIndex,
        address _account
    ) external view returns (uint256) {
        return auctions[_auctionIndex].bids[_account];
    }

    /// @notice Allows admins to withdraw ETH after a successful auction.
    /// @param _auctionIndex The auction to withdraw the ETH from
    function withdrawETH(uint256 _auctionIndex) external {
        Auction storage auction = auctions[_auctionIndex];
        if (auction.creator != msg.sender) revert Unauthorized();

        address _highestBidder = auction.highestBidOwner;
        if (
            auction.endTime > block.timestamp ||
            _highestBidder == address(0) ||
            auction.ownerClaimed
        ) revert Unauthorized();

        auction.ownerClaimed = true;

        (bool _sent, ) = payable(msg.sender).call{
            value: auction.bids[_highestBidder]
        }('');
        assert(_sent);

        emit ETHClaimed(_auctionIndex);
    }

    /// @notice Allows admins to withdraw an unsold NFT
    /// @param _auctionIndex The auction to withdraw the NFT from.
    function withdrawUnsoldNFT(uint256 _auctionIndex) external {
        Auction storage auction = auctions[_auctionIndex];
        if (auction.creator != msg.sender) revert Unauthorized();

        address _highestBidder = auction.highestBidOwner;
        if (
            auction.endTime > block.timestamp ||
            _highestBidder != address(0) ||
            auction.ownerClaimed
        ) revert Unauthorized();

        auction.ownerClaimed = true;

        auction.nftAddress.safeTransferFrom(
            address(this),
            msg.sender,
            auction.nftIndex,
            auction.amount,
            '0x'
        );

        emit AuctionFailed(_auctionIndex);
    }

    /// @notice Allows admins to set the amount of time to increase an auction by if a bid happens in the last few minutes
    /// @param _newTime The new amount of time
    function setBidTimeIncrement(
        uint256 _newTime
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newTime == 0) revert InvalidAmount();

        emit BidTimeIncrementChanged(_newTime, bidTimeIncrement);

        bidTimeIncrement = _newTime;
    }

    /// @notice Allows admins to set the minimum increment rate from the last highest bid.
    /// @param _newIncrementRate The new increment rate.
    function setMinimumIncrementRate(
        RateLib.Rate memory _newIncrementRate
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_newIncrementRate.isValid() && !_newIncrementRate.isBelowOne())
            revert RateLib.InvalidRate();

        emit MinimumIncrementRateChanged(_newIncrementRate, minIncrementRate);

        minIncrementRate = _newIncrementRate;
    }

    /// @notice Allows admins to set the default auction duration
    /// @param _duration The new default duration
    function setAuctionDuration(
        uint256 _duration
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_duration == 0) revert InvalidAmount();

        emit DurationChanged(_duration, auctionDuration);

        auctionDuration = _duration;
    }

    function _newAuction(
        address _owner,
        IERC1155Upgradeable _nft,
        uint256 _idx,
        uint256 _amount,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _minBid
    ) internal returns (uint256) {
        if (address(_nft) == address(0)) revert ZeroAddress();
        if (
            block.timestamp > _startTime ||
            _startTime >= _endTime ||
            _minBid == 0
        ) revert InvalidAmount();

        Auction storage auction = auctions[auctionsLength++];
        auction.creator = _owner;
        auction.nftAddress = _nft;
        auction.nftIndex = _idx;
        auction.amount = _amount;
        auction.startTime = _startTime;
        auction.endTime = _endTime;
        auction.minBid = _minBid;

        _nft.safeTransferFrom(msg.sender, address(this), _idx, _amount, '0x');

        emit NewAuction(auctionsLength - 1, _nft, _idx, _amount, _startTime);

        return auctionsLength - 1;
    }

    function _getNextSlotStart() internal view returns (uint256) {
        uint256 _duration = auctionDuration;
        return block.timestamp - (block.timestamp % _duration) + _duration;
    }

    // ERC1155 Receiver hooks

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return
            bytes4(
                keccak256(
                    'onERC1155Received(address,address,uint256,uint256,bytes)'
                )
            );
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external pure override returns (bytes4) {
        return
            bytes4(
                keccak256(
                    'onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)'
                )
            );
    }
}
