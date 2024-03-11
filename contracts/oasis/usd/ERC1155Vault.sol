// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155ReceiverUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';

import '../../interfaces/IStableCoin.sol';
import '../../utils/RateLib.sol';
import {ERC1155ValueProvider} from './ERC1155ValueProvider.sol';
import {AbstractAssetVault} from './AbstractAssetVault.sol';

/// @title ERC1155 lending vault
/// @notice This contracts allows users to borrow ShezmuUSD using ERC1155 as collateral.
/// The floor price of the NFT collection is fetched using a chainlink oracle, while some other more valuable traits
/// can have an higher price set by the DAO. Users can also increase the price (and thus the borrow limit) of their
/// NFT by submitting a governance proposal. If the proposal is approved the user can lock a percentage of the new price
/// worth of Shezmu to make it effective
contract ERC1155Vault is AbstractAssetVault, IERC1155ReceiverUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IStableCoin;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using RateLib for RateLib.Rate;
    /// @notice The Shezmu trait boost locker contract
    ERC1155ValueProvider public valueProvider;

    IERC1155Upgradeable public tokenContract;
    uint256 public tokenIndex;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _stablecoin ShezUSD address
    /// @param _tokenContract The collateral token address
    /// @param _valueProvider The collateral token value provider
    /// @param _settings Initial settings used by the contract
    function initialize(
        IStableCoin _stablecoin,
        IERC1155Upgradeable _tokenContract,
        uint256 _tokenIndex,
        ERC1155ValueProvider _valueProvider,
        VaultSettings calldata _settings
    ) external initializer {
        __initialize(_stablecoin, _settings);
        tokenContract = _tokenContract;
        tokenIndex = _tokenIndex;
        valueProvider = _valueProvider;
    }

    /// @dev See {addCollateral}
    function _addCollateral(
        address _account,
        uint256 _colAmount
    ) internal override {
        if (_colAmount == 0) revert InvalidAmount(_colAmount);

        tokenContract.safeTransferFrom(
            _account,
            address(this),
            tokenIndex,
            _colAmount,
            '0x'
        );

        Position storage position = positions[_account];

        if (!userIndexes.contains(_account)) {
            userIndexes.add(_account);
        }
        position.collateral += _colAmount;

        emit CollateralAdded(_account, _colAmount);
    }

    /// @dev See {removeCollateral}
    function _removeCollateral(
        address _account,
        uint256 _colAmount
    ) internal override {
        Position storage position = positions[_account];

        uint256 _debtAmount = _getDebtAmount(_account);
        uint256 _creditLimit = _getCreditLimit(
            _account,
            position.collateral - _colAmount
        );

        if (_debtAmount > _creditLimit) revert InsufficientCollateral();

        position.collateral -= _colAmount;

        if (position.collateral == 0) {
            delete positions[_account];
            userIndexes.remove(_account);
        }

        tokenContract.safeTransferFrom(
            address(this),
            _account,
            tokenIndex,
            _colAmount,
            '0x'
        );

        emit CollateralRemoved(_account, _colAmount);
    }

    /// @dev See {liquidate}
    function _liquidate(
        address _account,
        address _owner,
        address _recipient
    ) internal override {
        _checkRole(LIQUIDATOR_ROLE, _account);

        Position storage position = positions[_owner];
        uint256 colAmount = position.collateral;

        uint256 debtAmount = _getDebtAmount(_owner);
        if (debtAmount < _getLiquidationLimit(_owner, position.collateral))
            revert InvalidPosition(_owner);

        // burn all payment
        stablecoin.burnFrom(_account, debtAmount);

        // update debt portion
        totalDebtPortion -= position.debtPortion;
        totalDebtAmount -= debtAmount;
        position.debtPortion = 0;

        // transfer collateral to liquidator
        delete positions[_owner];
        userIndexes.remove(_owner);
        tokenContract.safeTransferFrom(
            address(this),
            _recipient,
            tokenIndex,
            colAmount,
            '0x'
        );

        emit Liquidated(_account, _owner, colAmount);
    }

    /// @dev Returns the credit limit
    /// @param _owner The position owner
    /// @param _colAmount The collateral amount
    /// @return The credit limit
    function _getCreditLimit(
        address _owner,
        uint256 _colAmount
    ) internal view override returns (uint256) {
        uint256 creditLimitUSD = valueProvider.getCreditLimitUSD(
            _owner,
            _colAmount
        );
        return creditLimitUSD;
    }

    /// @dev Returns the minimum amount of debt necessary to liquidate the position
    /// @param _owner The position owner
    /// @param _colAmount The collateral amount
    /// @return The minimum amount of debt to liquidate the position
    function _getLiquidationLimit(
        address _owner,
        uint256 _colAmount
    ) internal view override returns (uint256) {
        uint256 liquidationLimitUSD = valueProvider.getLiquidationLimitUSD(
            _owner,
            _colAmount
        );
        return liquidationLimitUSD;
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
