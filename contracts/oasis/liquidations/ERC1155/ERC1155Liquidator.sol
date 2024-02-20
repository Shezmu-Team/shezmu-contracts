// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import '@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155ReceiverUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

import {IChainlinkV3Aggregator} from '../../../interfaces/IChainlinkV3Aggregator.sol';
import {ERC1155Vault} from '../../usd/ERC1155Vault.sol';
import {ERC1155ShezmuAuction} from './ERC1155ShezmuAuction.sol';

/// @title Liquidator escrow contract
/// @notice Liquidator contract that allows liquidator bots to liquidate positions without holding any stablecoins/NFTs.
/// It's only meant to be used by DAO bots.
/// The liquidated NFTs are auctioned.
contract ERC1155Liquidator is OwnableUpgradeable, IERC1155ReceiverUpgradeable {
    using AddressUpgradeable for address;

    error ZeroAddress();
    error InvalidLength();
    error UnknownVault(ERC1155Vault vault);
    error InsufficientBalance(IERC20Upgradeable stablecoin);

    struct OracleInfo {
        IChainlinkV3Aggregator oracle;
        uint8 decimals;
    }

    struct VaultInfo {
        IERC20Upgradeable stablecoin;
        address nft;
        uint256 tokenIndex;
    }

    ERC1155ShezmuAuction public AUCTION;

    mapping(IERC20Upgradeable => OracleInfo) public stablecoinOracle;
    mapping(ERC1155Vault => VaultInfo) public vaultInfo;

    function initialize(address _auction) external initializer {
        __Ownable_init();

        if (_auction == address(0)) revert ZeroAddress();

        AUCTION = ERC1155ShezmuAuction(_auction);
    }

    /// @notice Allows any address to liquidate multiple positions at once.
    /// It assumes enough stablecoin is in the contract.
    /// The liquidated NFTs are sent to the DAO.
    /// This function can be called by anyone, however the address calling it doesn't get any stablecoins/NFTs.
    /// @dev This function doesn't revert if one of the positions is not liquidatable.
    /// This is done to prevent situations in which multiple positions can't be liquidated
    /// because of one not liquidatable position.
    /// It reverts on insufficient balance.
    /// @param _toLiquidate The user addresses to liquidate
    /// @param _nftVault The address of the NFTVault
    function liquidate(
        address[] memory _toLiquidate,
        ERC1155Vault _nftVault,
        address _auctionOwner
    ) external {
        VaultInfo memory _vaultInfo = vaultInfo[_nftVault];
        if (_vaultInfo.nft == address(0)) revert UnknownVault(_nftVault);

        uint256 _length = _toLiquidate.length;
        if (_length == 0) revert InvalidLength();

        uint256 _balance = _vaultInfo.stablecoin.balanceOf(address(this));
        _vaultInfo.stablecoin.approve(address(_nftVault), _balance);

        for (uint256 i; i < _length; ++i) {
            address _user = _toLiquidate[i];

            (uint256 collateral, uint256 debtPrincipal, ) = _nftVault.positions(
                _user
            );
            uint256 _interest = _nftVault.getDebtInterest(_user);

            try _nftVault.liquidate(_user, address(this)) {
                uint256 _normalizedDebt = _convertDebtAmount(
                    debtPrincipal + _interest,
                    stablecoinOracle[_vaultInfo.stablecoin]
                );

                IERC1155Upgradeable(_vaultInfo.nft).setApprovalForAll(
                    address(AUCTION),
                    true
                );

                AUCTION.newAuction(
                    _auctionOwner,
                    IERC1155Upgradeable(_vaultInfo.nft),
                    _vaultInfo.tokenIndex,
                    collateral,
                    _normalizedDebt
                );

                IERC1155Upgradeable(_vaultInfo.nft).setApprovalForAll(
                    address(AUCTION),
                    false
                );
            } catch Error(string memory _reason) {
                //insufficient allowance -> insufficient balance
                if (
                    keccak256(abi.encodePacked(_reason)) ==
                    keccak256(abi.encodePacked('ERC20: insufficient allowance'))
                ) revert InsufficientBalance(_vaultInfo.stablecoin);
            }
        }

        //reset appoval
        _vaultInfo.stablecoin.approve(address(_nftVault), 0);
    }

    /// @notice Allows the owner to add information about a NFTVault
    function addNFTVault(
        ERC1155Vault _nftVault,
        address _nft,
        uint256 _tokenIndex
    ) external onlyOwner {
        if (address(_nftVault) == address(0) || _nft == address(0))
            revert ZeroAddress();

        vaultInfo[_nftVault] = VaultInfo(
            IERC20Upgradeable(_nftVault.stablecoin()),
            _nft,
            _tokenIndex
        );
    }

    /// @notice Allows the owner to remove a NFTVault
    function removeNFTVault(ERC1155Vault _nftVault) external onlyOwner {
        delete vaultInfo[_nftVault];
    }

    /// @notice Allows the owner to set the oracle address for a specific stablecoin.
    function setOracle(
        IERC20Upgradeable _stablecoin,
        IChainlinkV3Aggregator _oracle
    ) external onlyOwner {
        if (
            address(_stablecoin) == address(0) || address(_oracle) == address(0)
        ) revert ZeroAddress();

        stablecoinOracle[_stablecoin] = OracleInfo(_oracle, _oracle.decimals());
    }

    /// @notice Allows the DAO to perform multiple calls using this contract (recovering funds/NFTs stuck in this contract)
    /// @param _targets The target addresses
    /// @param _calldatas The data to pass in each call
    /// @param _values The ETH value for each call
    function doCalls(
        address[] memory _targets,
        bytes[] memory _calldatas,
        uint256[] memory _values
    ) external payable onlyOwner {
        for (uint256 i = 0; i < _targets.length; i++) {
            _targets[i].functionCallWithValue(_calldatas[i], _values[i]);
        }
    }

    function _convertDebtAmount(
        uint256 _debt,
        OracleInfo memory _info
    ) internal view returns (uint256) {
        if (address(_info.oracle) == address(0)) return _debt;
        else {
            //not checking for stale prices because we have no fallback oracle
            //and stale/wrong prices are not an issue since they are only needed
            //to set the minimum bid for the auction
            (, int256 _answer, , , ) = _info.oracle.latestRoundData();

            return (_debt * 10 ** _info.decimals) / uint256(_answer);
        }
    }

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

    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool) {
        return
            interfaceId == type(IERC1155ReceiverUpgradeable).interfaceId;
    }
}
