// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol';
import '@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';

import '../../interfaces/IChainlinkV3Aggregator.sol';
import '../../interfaces/IStableCoin.sol';
import '../../utils/RateLib.sol';
import {ERC721ValueProvider} from './ERC721ValueProvider.sol';

/// @title ERC721 lending vault
/// @notice This contracts allows users to borrow ShezmuUSD using ERC721 as collateral.
/// The floor price of the NFT collection is fetched using a chainlink oracle, while some other more valuable traits
/// can have an higher price set by the DAO. Users can also increase the price (and thus the borrow limit) of their
/// NFT by submitting a governance proposal. If the proposal is approved the user can lock a percentage of the new price
/// worth of Shezmu to make it effective
contract ERC721Vault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IStableCoin;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using RateLib for RateLib.Rate;

    error InvalidNFT(uint256 nftIndex);
    error InvalidNFTType(bytes32 nftType);
    error InvalidUnlockTime(uint256 unlockTime);
    error InvalidAmount(uint256 amount);
    error InvalidPosition(uint256 nftIndex);
    error PositionLiquidated(uint256 nftIndex);
    error Unauthorized();
    error DebtCapReached();
    error InvalidInsuranceMode();
    error NoDebt();
    error NonZeroDebt(uint256 debtAmount);
    error PositionInsuranceExpired(uint256 nftIndex);
    error PositionInsuranceNotExpired(uint256 nftIndex);
    error ZeroAddress();
    error InvalidOracleResults();
    error UnknownAction(uint8 action);
    error InvalidLength();

    event PositionOpened(address indexed owner, uint256 indexed index);
    event Borrowed(
        address indexed owner,
        uint256 indexed index,
        uint256 amount,
        bool insured
    );
    event Repaid(address indexed owner, uint256 indexed index, uint256 amount);
    event PositionClosed(
        address indexed owner,
        uint256 indexed index,
        bool forced
    );
    event Liquidated(
        address indexed liquidator,
        address indexed owner,
        uint256 indexed index,
        bool insured
    );
    event LiquidationRepayment(
        address indexed owner,
        uint256 indexed index,
        uint256 repayAmount
    );
    event InsuranceExpired(address indexed owner, uint256 indexed index);

    event Accrual(uint256 additionalInterest);
    event FeeCollected(uint256 collectedAmount);

    enum BorrowType {
        NOT_CONFIRMED,
        NON_INSURANCE,
        USE_INSURANCE
    }

    struct Position {
        BorrowType borrowType;
        uint256 debtPrincipal;
        uint256 debtPortion;
        uint256 debtAmountForRepurchase;
        uint256 liquidatedAt;
        address liquidator;
    }

    struct VaultSettings {
        RateLib.Rate debtInterestApr;
        RateLib.Rate organizationFeeRate;
        RateLib.Rate insurancePurchaseRate;
        RateLib.Rate insuranceLiquidationPenaltyRate;
        uint256 insuranceRepurchaseTimeLimit;
        uint256 borrowAmountCap;
    }

    bytes32 private constant DAO_ROLE = keccak256('DAO_ROLE');
    bytes32 private constant LIQUIDATOR_ROLE = keccak256('LIQUIDATOR_ROLE');
    bytes32 private constant SETTER_ROLE = keccak256('SETTER_ROLE');

    //accrue required
    uint8 private constant ACTION_BORROW = 0;
    uint8 private constant ACTION_REPAY = 1;
    uint8 private constant ACTION_CLOSE_POSITION = 2;
    uint8 private constant ACTION_LIQUIDATE = 3;
    //no accrue required
    uint8 private constant ACTION_REPURCHASE = 100;
    uint8 private constant ACTION_CLAIM_NFT = 101;

    IStableCoin public stablecoin;
    /// @notice Chainlink ETH/USD price feed
    IChainlinkV3Aggregator public ethAggregator;
    /// @notice The Shezmu trait boost locker contract
    ERC721ValueProvider public valueProvider;

    IERC721Upgradeable public nftContract;

    /// @notice Total outstanding debt
    uint256 public totalDebtAmount;
    /// @dev Last time debt was accrued. See {accrue} for more info
    uint256 private totalDebtAccruedAt;
    uint256 public totalFeeCollected;
    uint256 private totalDebtPortion;

    VaultSettings public settings;

    /// @dev Keeps track of all the NFTs used as collateral for positions
    EnumerableSetUpgradeable.UintSet private positionIndexes;

    mapping(uint256 => Position) public positions;
    mapping(uint256 => address) public positionOwner;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _stablecoin ShezUSD address
    /// @param _nftContract The NFT contract address. It could also be the address of an helper contract
    /// if the target NFT isn't an ERC721 (CryptoPunks as an example)
    /// @param _valueProvider The NFT value provider
    /// @param _ethAggregator Chainlink ETH/USD price feed address
    /// @param _settings Initial settings used by the contract
    function initialize(
        IStableCoin _stablecoin,
        IERC721Upgradeable _nftContract,
        ERC721ValueProvider _valueProvider,
        IChainlinkV3Aggregator _ethAggregator,
        VaultSettings calldata _settings
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setupRole(DAO_ROLE, msg.sender);
        _setRoleAdmin(LIQUIDATOR_ROLE, DAO_ROLE);
        _setRoleAdmin(SETTER_ROLE, DAO_ROLE);
        _setRoleAdmin(DAO_ROLE, DAO_ROLE);

        if (
            !_settings.debtInterestApr.isValid() ||
            !_settings.debtInterestApr.isBelowOne()
        ) revert RateLib.InvalidRate();

        if (
            !_settings.organizationFeeRate.isValid() ||
            !_settings.organizationFeeRate.isBelowOne()
        ) revert RateLib.InvalidRate();

        if (
            !_settings.insurancePurchaseRate.isValid() ||
            !_settings.insurancePurchaseRate.isBelowOne()
        ) revert RateLib.InvalidRate();

        if (
            !_settings.insuranceLiquidationPenaltyRate.isValid() ||
            !_settings.insuranceLiquidationPenaltyRate.isBelowOne()
        ) revert RateLib.InvalidRate();

        stablecoin = _stablecoin;
        ethAggregator = _ethAggregator;
        nftContract = _nftContract;
        valueProvider = _valueProvider;

        settings = _settings;
    }

    /// @notice Returns the number of open positions
    /// @return The number of open positions
    function totalPositions() external view returns (uint256) {
        return positionIndexes.length();
    }

    /// @notice Returns all open position NFT indexes
    /// @return The open position NFT indexes
    function openPositionsIndexes() external view returns (uint256[] memory) {
        return positionIndexes.values();
    }

    /// @param _nftIndex The NFT to return the credit limit of
    /// @return The ShezUSD credit limit of the NFT at index `_nftIndex`.
    function getCreditLimit(
        address _owner,
        uint256 _nftIndex
    ) external view returns (uint256) {
        return _getCreditLimit(_owner, _nftIndex);
    }

    /// @param _nftIndex The NFT to return the liquidation limit of
    /// @return The ShezUSD liquidation limit of the NFT at index `_nftIndex`.
    function getLiquidationLimit(
        address _owner,
        uint256 _nftIndex
    ) public view returns (uint256) {
        return _getLiquidationLimit(_owner, _nftIndex);
    }

    /// @param _nftIndex The NFT to check
    /// @return Whether the NFT at index `_nftIndex` is liquidatable.
    function isLiquidatable(uint256 _nftIndex) external view returns (bool) {
        Position storage position = positions[_nftIndex];
        if (position.borrowType == BorrowType.NOT_CONFIRMED) return false;
        if (position.liquidatedAt > 0) return false;

        uint256 principal = position.debtPrincipal;
        return
            principal + getDebtInterest(_nftIndex) >=
            getLiquidationLimit(positionOwner[_nftIndex], _nftIndex);
    }

    /// @param _nftIndex The NFT to check
    /// @return The ShezUSD debt interest accumulated by the NFT at index `_nftIndex`.
    function getDebtInterest(uint256 _nftIndex) public view returns (uint256) {
        Position storage position = positions[_nftIndex];
        uint256 principal = position.debtPrincipal;
        uint256 debt = position.liquidatedAt != 0
            ? position.debtAmountForRepurchase
            : _calculateDebt(
                totalDebtAmount + calculateAdditionalInterest(),
                position.debtPortion,
                totalDebtPortion
            );

        //_calculateDebt is prone to rounding errors that may cause
        //the calculated debt amount to be 1 or 2 units less than
        //the debt principal if no time has elapsed in between the first borrow
        //and the _calculateDebt call.
        if (principal > debt) debt = principal;

        unchecked {
            return debt - principal;
        }
    }

    /// @dev Calculates the additional global interest since last time the contract's state was updated by calling {accrue}
    /// @return The additional interest value
    function calculateAdditionalInterest() public view returns (uint256) {
        // Number of seconds since {accrue} was called
        uint256 elapsedTime = block.timestamp - totalDebtAccruedAt;
        if (elapsedTime == 0) {
            return 0;
        }

        uint256 totalDebt = totalDebtAmount;
        if (totalDebt == 0) {
            return 0;
        }

        // Accrue interest
        return
            (elapsedTime * totalDebt * settings.debtInterestApr.numerator) /
            settings.debtInterestApr.denominator /
            365 days;
    }

    /// @dev The {accrue} function updates the contract's state by calculating
    /// the additional interest accrued since the last state update
    function accrue() public {
        uint256 additionalInterest = calculateAdditionalInterest();

        totalDebtAccruedAt = block.timestamp;

        totalDebtAmount += additionalInterest;
        totalFeeCollected += additionalInterest;

        emit Accrual(additionalInterest);
    }

    /// @notice Allows to execute multiple actions in a single transaction.
    /// @param _actions The actions to execute.
    /// @param _data The abi encoded parameters for the actions to execute.
    function doActions(
        uint8[] calldata _actions,
        bytes[] calldata _data
    ) external nonReentrant {
        _doActionsFor(msg.sender, _actions, _data);
    }

    /// @notice Allows users to open positions and borrow using an NFT
    /// @dev emits a {Borrowed} event
    /// @param _nftIndex The index of the NFT to be used as collateral
    /// @param _amount The amount of ShezUSD to be borrowed. Note that the user will receive less than the amount requested,
    /// the borrow fee and insurance automatically get removed from the amount borrowed
    /// @param _useInsurance Whereter to open an insured position. In case the position has already been opened previously,
    /// this parameter needs to match the previous insurance mode. To change insurance mode, a user needs to close and reopen the position
    function borrow(
        uint256 _nftIndex,
        uint256 _amount,
        bool _useInsurance
    ) external nonReentrant {
        accrue();
        _borrow(msg.sender, _nftIndex, _amount, _useInsurance);
    }

    /// @notice Allows users to repay a portion/all of their debt. Note that since interest increases every second,
    /// a user wanting to repay all of their debt should repay for an amount greater than their current debt to account for the
    /// additional interest while the repay transaction is pending, the contract will only take what's necessary to repay all the debt
    /// @dev Emits a {Repaid} event
    /// @param _nftIndex The NFT used as collateral for the position
    /// @param _amount The amount of debt to repay. If greater than the position's outstanding debt, only the amount necessary to repay all the debt will be taken
    function repay(uint256 _nftIndex, uint256 _amount) external nonReentrant {
        accrue();
        _repay(msg.sender, _nftIndex, _amount);
    }

    /// @notice Allows a user to close a position and get their collateral back, if the position's outstanding debt is 0
    /// @dev Emits a {PositionClosed} event
    /// @param _nftIndex The index of the NFT used as collateral
    function closePosition(uint256 _nftIndex) external nonReentrant {
        accrue();
        _closePosition(msg.sender, _nftIndex);
    }

    /// @notice Allows members of the `LIQUIDATOR_ROLE` to liquidate a position. Positions can only be liquidated
    /// once their debt amount exceeds the minimum liquidation debt to collateral value rate.
    /// In order to liquidate a position, the liquidator needs to repay the user's outstanding debt.
    /// If the position is not insured, it's closed immediately and the collateral is sent to `_recipient`.
    /// If the position is insured, the position remains open (interest doesn't increase) and the owner of the position has a certain amount of time
    /// (`insuranceRepurchaseTimeLimit`) to fully repay the liquidator and pay an additional liquidation fee (`insuranceLiquidationPenaltyRate`), if this
    /// is done in time the user gets back their collateral and their position is automatically closed. If the user doesn't repurchase their collateral
    /// before the time limit passes, the liquidator can claim the liquidated NFT and the position is closed
    /// @dev Emits a {Liquidated} event
    /// @param _nftIndex The NFT to liquidate
    /// @param _recipient The address to send the NFT to
    function liquidate(
        uint256 _nftIndex,
        address _recipient
    ) external nonReentrant {
        accrue();
        _liquidate(msg.sender, _nftIndex, _recipient);
    }

    /// @notice Allows liquidated users who purchased insurance to repurchase their collateral within the time limit
    /// defined with the `insuranceRepurchaseTimeLimit`. The user needs to repay enough for the position's debt to fall below its credit limit,
    /// plus an insurance liquidation fee defined with `insuranceLiquidationPenaltyRate`
    /// @dev Emits a {LiquidationRepayment} event
    /// @param _nftIndex The NFT to repurchase
    /// @param _repayAmount The amount of debt to repay. The new debt amount must be lower than the credit limit
    function repurchase(
        uint256 _nftIndex,
        uint256 _repayAmount
    ) external nonReentrant {
        _repurchase(msg.sender, _nftIndex, _repayAmount);
    }

    /// @notice Allows the liquidator who liquidated the insured position with NFT at index `_nftIndex` to claim the position's collateral
    /// after the time period defined with `insuranceRepurchaseTimeLimit` has expired and the position owner has not repurchased the collateral.
    /// @dev Emits an {InsuranceExpired} event
    /// @param _nftIndex The NFT to claim
    /// @param _recipient The address to send the NFT to
    function claimExpiredInsuranceNFT(
        uint256 _nftIndex,
        address _recipient
    ) external nonReentrant {
        _claimExpiredInsuranceNFT(msg.sender, _nftIndex, _recipient);
    }

    /// @notice Allows the DAO to collect interest and fees before they are repaid
    function collect() external nonReentrant onlyRole(DAO_ROLE) {
        accrue();

        uint256 _totalFeeCollected = totalFeeCollected;

        stablecoin.mint(msg.sender, _totalFeeCollected);
        totalFeeCollected = 0;

        emit FeeCollected(_totalFeeCollected);
    }

    /// @notice Allows the DAO to withdraw _amount of an ERC20
    function rescueToken(
        IERC20Upgradeable _token,
        uint256 _amount
    ) external nonReentrant onlyRole(DAO_ROLE) {
        _token.safeTransfer(msg.sender, _amount);
    }

    /// @notice Allows the setter contract to change fields in the `VaultSettings` struct.
    /// @dev Validation and single field setting is handled by an external contract with the
    /// `SETTER_ROLE`. This was done to reduce the contract's size.
    function setSettings(
        VaultSettings calldata _settings
    ) external onlyRole(SETTER_ROLE) {
        settings = _settings;
    }

    /// @dev Opens a position
    /// Emits a {PositionOpened} event
    /// @param _owner The owner of the position to open
    /// @param _nftIndex The NFT used as collateral for the position
    function _openPosition(address _owner, uint256 _nftIndex) internal {
        positionOwner[_nftIndex] = _owner;
        positionIndexes.add(_nftIndex);

        nftContract.transferFrom(_owner, address(this), _nftIndex);

        emit PositionOpened(_owner, _nftIndex);
    }

    /// @dev See {doActions}
    function _doActionsFor(
        address _account,
        uint8[] calldata _actions,
        bytes[] calldata _data
    ) internal {
        if (_actions.length != _data.length) revert InvalidLength();
        bool accrueCalled;
        for (uint256 i; i < _actions.length; ++i) {
            uint8 action = _actions[i];
            if (!accrueCalled && action < 100) {
                accrue();
                accrueCalled = true;
            }

            if (action == ACTION_BORROW) {
                (uint256 nftIndex, uint256 amount, bool useInsurance) = abi
                    .decode(_data[i], (uint256, uint256, bool));
                _borrow(_account, nftIndex, amount, useInsurance);
            } else if (action == ACTION_REPAY) {
                (uint256 nftIndex, uint256 amount) = abi.decode(
                    _data[i],
                    (uint256, uint256)
                );
                _repay(_account, nftIndex, amount);
            } else if (action == ACTION_CLOSE_POSITION) {
                uint256 nftIndex = abi.decode(_data[i], (uint256));
                _closePosition(_account, nftIndex);
            } else if (action == ACTION_LIQUIDATE) {
                (uint256 nftIndex, address recipient) = abi.decode(
                    _data[i],
                    (uint256, address)
                );
                _liquidate(_account, nftIndex, recipient);
            } else if (action == ACTION_REPURCHASE) {
                (uint256 nftIndex, uint256 newDebtAmount) = abi.decode(
                    _data[i],
                    (uint256, uint256)
                );
                _repurchase(_account, nftIndex, newDebtAmount);
            } else if (action == ACTION_CLAIM_NFT) {
                (uint256 nftIndex, address recipient) = abi.decode(
                    _data[i],
                    (uint256, address)
                );
                _claimExpiredInsuranceNFT(_account, nftIndex, recipient);
            } else {
                revert UnknownAction(action);
            }
        }
    }

    /// @dev See {borrow}
    function _borrow(
        address _account,
        uint256 _nftIndex,
        uint256 _amount,
        bool _useInsurance
    ) internal {
        _validNFTIndex(_nftIndex);

        address _owner = positionOwner[_nftIndex];
        if (_owner != _account && _owner != address(0)) revert Unauthorized();

        if (_amount == 0 && _owner != address(0)) revert InvalidAmount(_amount);

        uint256 _totalDebtAmount = totalDebtAmount;
        if (_totalDebtAmount + _amount > settings.borrowAmountCap)
            revert DebtCapReached();

        Position storage position = positions[_nftIndex];
        if (position.liquidatedAt != 0) revert PositionLiquidated(_nftIndex);

        BorrowType _borrowType = position.borrowType;
        BorrowType _targetBorrowType = _useInsurance
            ? BorrowType.USE_INSURANCE
            : BorrowType.NON_INSURANCE;

        if (_borrowType == BorrowType.NOT_CONFIRMED)
            position.borrowType = _targetBorrowType;
        else if (_borrowType != _targetBorrowType)
            revert InvalidInsuranceMode();

        uint256 _creditLimit = _getCreditLimit(_account, _nftIndex);
        uint256 _debtAmount = _getDebtAmount(_nftIndex);
        if (_debtAmount + _amount > _creditLimit) revert InvalidAmount(_amount);

        //calculate the borrow fee
        uint256 _organizationFee = (_amount *
            settings.organizationFeeRate.numerator) /
            settings.organizationFeeRate.denominator;

        uint256 _feeAmount = _organizationFee;
        //if the position is insured, calculate the insurance fee
        if (_targetBorrowType == BorrowType.USE_INSURANCE) {
            _feeAmount +=
                (_amount * settings.insurancePurchaseRate.numerator) /
                settings.insurancePurchaseRate.denominator;
        }
        totalFeeCollected += _feeAmount;

        // update debt portion
        {
            uint256 _totalDebtPortion = totalDebtPortion;
            uint256 _plusPortion = _calculatePortion(
                _totalDebtPortion,
                _amount,
                _totalDebtAmount
            );

            totalDebtPortion = _totalDebtPortion + _plusPortion;
            position.debtPortion += _plusPortion;
            position.debtPrincipal += _amount;
            totalDebtAmount = _totalDebtAmount + _amount;
        }

        if (positionOwner[_nftIndex] == address(0)) {
            _openPosition(_account, _nftIndex);
        }

        if (_amount - _feeAmount > 0) {
            //subtract the fee from the amount borrowed
            stablecoin.mint(_account, _amount - _feeAmount);
        }

        emit Borrowed(_account, _nftIndex, _amount, _useInsurance);
    }

    /// @dev See {repay}
    function _repay(
        address _account,
        uint256 _nftIndex,
        uint256 _amount
    ) internal {
        _validNFTIndex(_nftIndex);

        if (_account != positionOwner[_nftIndex]) revert Unauthorized();

        if (_amount == 0) revert InvalidAmount(_amount);

        Position storage position = positions[_nftIndex];
        if (position.liquidatedAt > 0) revert PositionLiquidated(_nftIndex);

        uint256 _debtAmount = _getDebtAmount(_nftIndex);
        if (_debtAmount == 0) revert NoDebt();

        uint256 _debtPrincipal = position.debtPrincipal;
        uint256 _debtInterest = _debtAmount - _debtPrincipal;

        _amount = _amount > _debtAmount ? _debtAmount : _amount;

        // burn all payment, the interest is sent to the DAO using the {collect} function
        stablecoin.burnFrom(_account, _amount);

        uint256 _paidPrincipal;

        unchecked {
            _paidPrincipal = _amount > _debtInterest
                ? _amount - _debtInterest
                : 0;
        }

        uint256 _totalDebtPortion = totalDebtPortion;
        uint256 _totalDebtAmount = totalDebtAmount;
        uint256 _debtPortion = position.debtPortion;
        uint256 _minusPortion = _paidPrincipal == _debtPrincipal
            ? _debtPortion
            : _calculatePortion(_totalDebtPortion, _amount, _totalDebtAmount);

        totalDebtPortion = _totalDebtPortion - _minusPortion;
        position.debtPortion = _debtPortion - _minusPortion;
        position.debtPrincipal = _debtPrincipal - _paidPrincipal;
        totalDebtAmount = _totalDebtAmount - _amount;

        emit Repaid(_account, _nftIndex, _amount);
    }

    /// @dev See {closePosition}
    function _closePosition(address _account, uint256 _nftIndex) internal {
        _validNFTIndex(_nftIndex);

        if (_account != positionOwner[_nftIndex]) revert Unauthorized();

        Position storage position = positions[_nftIndex];
        if (position.liquidatedAt > 0) revert PositionLiquidated(_nftIndex);

        uint256 debt = _getDebtAmount(_nftIndex);
        if (debt > 0) revert NonZeroDebt(debt);

        positionOwner[_nftIndex] = address(0);
        delete positions[_nftIndex];
        positionIndexes.remove(_nftIndex);

        nftContract.safeTransferFrom(address(this), _account, _nftIndex);

        emit PositionClosed(_account, _nftIndex, false);
    }

    /// @dev See {liquidate}
    function _liquidate(
        address _account,
        uint256 _nftIndex,
        address _recipient
    ) internal {
        _checkRole(LIQUIDATOR_ROLE, _account);
        _validNFTIndex(_nftIndex);

        address posOwner = positionOwner[_nftIndex];
        if (posOwner == address(0)) revert InvalidPosition(_nftIndex);

        Position storage position = positions[_nftIndex];
        if (position.liquidatedAt > 0) revert PositionLiquidated(_nftIndex);

        uint256 debtAmount = _getDebtAmount(_nftIndex);
        if (debtAmount < _getLiquidationLimit(posOwner, _nftIndex))
            revert InvalidPosition(_nftIndex);

        // burn all payment
        stablecoin.burnFrom(_account, debtAmount);

        // update debt portion
        totalDebtPortion -= position.debtPortion;
        totalDebtAmount -= debtAmount;
        position.debtPortion = 0;

        bool insured = position.borrowType == BorrowType.USE_INSURANCE;
        if (insured) {
            position.debtAmountForRepurchase = debtAmount;
            position.liquidatedAt = block.timestamp;
            position.liquidator = _account;
        } else {
            // transfer nft to liquidator
            positionOwner[_nftIndex] = address(0);
            delete positions[_nftIndex];
            positionIndexes.remove(_nftIndex);
            nftContract.transferFrom(address(this), _recipient, _nftIndex);
        }

        emit Liquidated(_account, posOwner, _nftIndex, insured);
    }

    /// @dev See {repurchase}
    function _repurchase(
        address _account,
        uint256 _nftIndex,
        uint256 _repayAmount
    ) internal {
        _validNFTIndex(_nftIndex);
        if (_account != positionOwner[_nftIndex]) revert Unauthorized();

        Position storage position = positions[_nftIndex];
        uint256 _liquidatedAt = position.liquidatedAt;
        if (_liquidatedAt == 0) revert InvalidPosition(_nftIndex);
        if (position.borrowType != BorrowType.USE_INSURANCE)
            revert InvalidPosition(_nftIndex);
        if (
            block.timestamp >=
            _liquidatedAt + settings.insuranceRepurchaseTimeLimit
        ) revert PositionInsuranceExpired(_nftIndex);

        uint256 _debtAmount = position.debtAmountForRepurchase;
        if (_repayAmount > _debtAmount || _repayAmount == 0)
            revert InvalidAmount(_repayAmount);

        uint256 _newDebtAmount = _debtAmount - _repayAmount;
        uint256 _creditLimit = _getCreditLimit(_account, _nftIndex);
        if (_newDebtAmount > _creditLimit) revert InvalidAmount(_repayAmount);

        uint256 _penalty = (_debtAmount *
            settings.insuranceLiquidationPenaltyRate.numerator) /
            settings.insuranceLiquidationPenaltyRate.denominator;

        uint256 _totalDebtPortion = totalDebtPortion;
        uint256 _totalDebtAmount = totalDebtAmount;
        uint256 _plusPortion = _calculatePortion(
            _totalDebtPortion,
            _newDebtAmount,
            _totalDebtAmount
        );

        totalDebtPortion = _totalDebtPortion + _plusPortion;
        totalDebtAmount = _totalDebtAmount + _newDebtAmount;
        position.debtPortion = _plusPortion;
        position.debtPrincipal = _newDebtAmount;
        delete position.debtAmountForRepurchase;
        delete position.liquidatedAt;

        address _liquidator = position.liquidator;
        delete position.liquidator;

        totalFeeCollected += _penalty;

        IStableCoin _stablecoin = stablecoin;
        _stablecoin.burnFrom(_account, _repayAmount + _penalty);
        _stablecoin.mint(_liquidator, _debtAmount);

        emit LiquidationRepayment(_account, _nftIndex, _repayAmount);
    }

    /// @dev See {claimExpiredInsuranceNFT}
    function _claimExpiredInsuranceNFT(
        address _account,
        uint256 _nftIndex,
        address _recipient
    ) internal {
        _validNFTIndex(_nftIndex);

        if (_recipient == address(0)) revert ZeroAddress();
        Position memory position = positions[_nftIndex];
        address owner = positionOwner[_nftIndex];
        if (owner == address(0)) revert InvalidPosition(_nftIndex);
        if (position.liquidatedAt == 0) revert InvalidPosition(_nftIndex);
        if (
            position.liquidatedAt + settings.insuranceRepurchaseTimeLimit >
            block.timestamp
        ) revert PositionInsuranceNotExpired(_nftIndex);
        if (position.liquidator != _account) revert Unauthorized();

        positionOwner[_nftIndex] = address(0);
        delete positions[_nftIndex];
        positionIndexes.remove(_nftIndex);

        nftContract.transferFrom(address(this), _recipient, _nftIndex);

        emit InsuranceExpired(owner, _nftIndex);
    }

    function _validNFTIndex(uint256 _nftIndex) internal view {
        if (nftContract.ownerOf(_nftIndex) == address(0))
            revert InvalidNFT(_nftIndex);
    }

    /// @dev Returns the credit limit of an NFT
    /// @param _owner The owner of the NFT
    /// @param _nftIndex The NFT to return credit limit of
    /// @return The NFT credit limit
    function _getCreditLimit(
        address _owner,
        uint256 _nftIndex
    ) internal view returns (uint256) {
        uint256 creditLimitETH = valueProvider.getCreditLimitETH(
            _owner,
            _nftIndex
        );
        return _ethToUSD(creditLimitETH);
    }

    /// @dev Returns the minimum amount of debt necessary to liquidate an NFT
    /// @param _owner The owner of the NFT
    /// @param _nftIndex The index of the NFT
    /// @return The minimum amount of debt to liquidate the NFT
    function _getLiquidationLimit(
        address _owner,
        uint256 _nftIndex
    ) internal view returns (uint256) {
        uint256 liquidationLimitETH = valueProvider.getLiquidationLimitETH(
            _owner,
            _nftIndex
        );
        return _ethToUSD(liquidationLimitETH);
    }

    /// @dev Calculates current outstanding debt of an NFT
    /// @param _nftIndex The NFT to calculate the outstanding debt of
    /// @return The outstanding debt value
    function _getDebtAmount(uint256 _nftIndex) internal view returns (uint256) {
        uint256 calculatedDebt = _calculateDebt(
            totalDebtAmount,
            positions[_nftIndex].debtPortion,
            totalDebtPortion
        );

        uint256 principal = positions[_nftIndex].debtPrincipal;

        //_calculateDebt is prone to rounding errors that may cause
        //the calculated debt amount to be 1 or 2 units less than
        //the debt principal when the accrue() function isn't called
        //in between the first borrow and the _calculateDebt call.
        return principal > calculatedDebt ? principal : calculatedDebt;
    }

    /// @dev Calculates the total debt of a position given the global debt, the user's portion of the debt and the total user portions
    /// @param total The global outstanding debt
    /// @param userPortion The user's portion of debt
    /// @param totalPortion The total user portions of debt
    /// @return The outstanding debt of the position
    function _calculateDebt(
        uint256 total,
        uint256 userPortion,
        uint256 totalPortion
    ) internal pure returns (uint256) {
        return totalPortion == 0 ? 0 : (total * userPortion) / totalPortion;
    }

    /// @dev Calculates the debt portion of a position given the global debt portion, the debt amount and the global debt amount
    /// @param _total The total user portions of debt
    /// @param _userDebt The user's debt
    /// @param _totalDebt The global outstanding debt
    /// @return _userDebt converted into a debt portion
    function _calculatePortion(
        uint256 _total,
        uint256 _userDebt,
        uint256 _totalDebt
    ) internal pure returns (uint256) {
        return _total == 0 ? _userDebt : (_total * _userDebt) / _totalDebt;
    }

    /// @dev Converts an ETH value in USD
    function _ethToUSD(uint256 _ethValue) internal view returns (uint256) {
        return
            (_ethValue * _normalizeAggregatorAnswer(ethAggregator)) / 1 ether;
    }

    /// @dev Fetches and converts to 18 decimals precision the latest answer of a Chainlink aggregator
    /// @param aggregator The aggregator to fetch the answer from
    /// @return The latest aggregator answer, normalized
    function _normalizeAggregatorAnswer(
        IChainlinkV3Aggregator aggregator
    ) internal view returns (uint256) {
        (, int256 answer, , uint256 timestamp, ) = aggregator.latestRoundData();

        if (answer == 0 || timestamp == 0) revert InvalidOracleResults();

        uint8 decimals = aggregator.decimals();

        unchecked {
            //converts the answer to have 18 decimals
            return
                decimals > 18
                    ? uint256(answer) / 10 ** (decimals - 18)
                    : uint256(answer) * 10 ** (18 - decimals);
        }
    }
}
