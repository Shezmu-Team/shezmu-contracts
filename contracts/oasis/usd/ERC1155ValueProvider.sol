// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';

import '../../utils/AccessControlUpgradeable.sol';
import '../../utils/RateLib.sol';
import '../../interfaces/IChainlinkV3Aggregator.sol';

abstract contract ERC1155ValueProvider is
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable
{
    using RateLib for RateLib.Rate;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    error InvalidAmount(uint256 amount);
    error ZeroAddress();
    error InvalidOracleResults();

    event DaoFloorChanged(uint256 newFloor);

    /// @notice The NFT floor oracles aggregator
    IChainlinkV3Aggregator public aggregator;
    /// @notice If true, the floor price won't be fetched using the Chainlink oracle but
    /// a value set by the DAO will be used instead
    bool public daoFloorOverride;
    /// @notice Value of floor set by the DAO. Only used if `daoFloorOverride` is true
    uint256 public overriddenFloorValueUSD;

    RateLib.Rate public baseCreditLimitRate;
    RateLib.Rate public baseLiquidationLimitRate;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _aggregator The NFT floor oracles aggregator
    /// @param _baseCreditLimitRate The base credit limit rate
    /// @param _baseLiquidationLimitRate The base liquidation limit rate
    function __initialize(
        IChainlinkV3Aggregator _aggregator,
        RateLib.Rate calldata _baseCreditLimitRate,
        RateLib.Rate calldata _baseLiquidationLimitRate
    ) internal onlyInitializing {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _validateRateBelowOne(_baseCreditLimitRate);
        _validateRateBelowOne(_baseLiquidationLimitRate);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        aggregator = _aggregator;
        baseCreditLimitRate = _baseCreditLimitRate;
        baseLiquidationLimitRate = _baseLiquidationLimitRate;
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The credit limit rate
    function getCreditLimitRate(
        address _owner,
        uint256 _colAmount
    ) public view returns (RateLib.Rate memory) {
        return baseCreditLimitRate;
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The liquidation limit rate
    function getLiquidationLimitRate(
        address _owner,
        uint256 _colAmount
    ) public view returns (RateLib.Rate memory) {
        return baseLiquidationLimitRate;
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The credit limit for collateral amount
    function getCreditLimitUSD(
        address _owner,
        uint256 _colAmount
    ) external view returns (uint256) {
        RateLib.Rate memory _creditLimitRate = getCreditLimitRate(
            _owner,
            _colAmount
        );
        return _creditLimitRate.calculate(getNFTValueUSD(_colAmount));
    }

    /// @param _owner The owner address
    /// @param _colAmount The collateral amount
    /// @return The liquidation limit for collateral amount
    function getLiquidationLimitUSD(
        address _owner,
        uint256 _colAmount
    ) external view returns (uint256) {
        RateLib.Rate memory _liquidationLimitRate = getLiquidationLimitRate(
            _owner,
            _colAmount
        );
        return _liquidationLimitRate.calculate(getNFTValueUSD(_colAmount));
    }

    /// @return The floor value for the collection, in USD.
    function getFloorUSD() public view virtual returns (uint256) {
        if (daoFloorOverride) {
            return overriddenFloorValueUSD;
        }

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

    /// @param _colAmount The collateral amount
    /// @return The value in USD of the NFT at index `_nftIndex`, with 18 decimals.
    function getNFTValueUSD(uint256 _colAmount) public view returns (uint256) {
        uint256 _floor = getFloorUSD();
        return _floor * _colAmount;
    }

    /// @notice Allows the DAO to bypass the floor oracle and override the NFT floor value
    /// @param _newFloor The new floor
    function overrideFloor(
        uint256 _newFloor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newFloor == 0) revert InvalidAmount(_newFloor);
        overriddenFloorValueUSD = _newFloor;
        daoFloorOverride = true;

        emit DaoFloorChanged(_newFloor);
    }

    /// @notice Allows the DAO to stop overriding floor
    function disableFloorOverride() external onlyRole(DEFAULT_ADMIN_ROLE) {
        daoFloorOverride = false;
    }

    function setBaseCreditLimitRate(
        RateLib.Rate memory _baseCreditLimitRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRateBelowOne(_baseCreditLimitRate);

        baseCreditLimitRate = _baseCreditLimitRate;
    }

    function setBaseLiquidationLimitRate(
        RateLib.Rate memory _liquidationLimitRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRateBelowOne(_liquidationLimitRate);

        baseLiquidationLimitRate = _liquidationLimitRate;
    }

    /// @dev Validates a rate. The denominator must be greater than zero and greater than or equal to the numerator.
    /// @param _rate The rate to validate
    function _validateRateBelowOne(RateLib.Rate memory _rate) internal pure {
        if (!_rate.isValid() || _rate.isAboveOne())
            revert RateLib.InvalidRate();
    }
}
