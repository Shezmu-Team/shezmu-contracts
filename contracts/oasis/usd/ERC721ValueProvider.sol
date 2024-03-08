// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol';

import '../../utils/AccessControlUpgradeable.sol';
import '../../utils/RateLib.sol';
import '../../interfaces/IChainlinkV3Aggregator.sol';

contract ERC721ValueProvider is
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable
{
    using RateLib for RateLib.Rate;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    error InvalidNFTType(bytes32 nftType);
    error InvalidAmount(uint256 amount);
    error ZeroAddress();
    error InvalidOracleResults();

    event DaoFloorChanged(uint256 newFloor);
    event NewBaseCreditLimitRate(RateLib.Rate rate);
    event NewBaseLiquidationLimitRate(RateLib.Rate rate);
    event NewNFTTypeMultiplier(bytes32 nftType, RateLib.Rate multiplier);

    /// @notice The NFT floor oracles aggregator
    IChainlinkV3Aggregator public aggregator;
    /// @notice If true, the floor price won't be fetched using the Chainlink oracle but
    /// a value set by the DAO will be used instead
    bool public daoFloorOverride;
    /// @notice Value of floor set by the DAO. Only used if `daoFloorOverride` is true
    uint256 private overriddenFloorValueETH;

    mapping(uint256 => bytes32) public nftTypes;
    mapping(bytes32 => RateLib.Rate) public nftTypeValueMultiplier;
    /// @custom:oz-renamed-from lockPositions

    RateLib.Rate public baseCreditLimitRate;
    RateLib.Rate public baseLiquidationLimitRate;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _aggregator The NFT floor oracles aggregator
    /// @param _baseCreditLimitRate The base credit limit rate
    /// @param _baseLiquidationLimitRate The base liquidation limit rate
    function initialize(
        IChainlinkV3Aggregator _aggregator,
        RateLib.Rate calldata _baseCreditLimitRate,
        RateLib.Rate calldata _baseLiquidationLimitRate
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (address(_aggregator) == address(0)) revert ZeroAddress();

        _validateRateBelowOne(_baseCreditLimitRate);
        _validateRateBelowOne(_baseLiquidationLimitRate);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        aggregator = _aggregator;
        baseCreditLimitRate = _baseCreditLimitRate;
        baseLiquidationLimitRate = _baseLiquidationLimitRate;
    }

    /// @param _owner The owner of the NFT at index `_nftIndex` (or the owner of the associated position in the vault)
    /// @param _nftIndex The index of the NFT to return the credit limit rate for
    /// @return The credit limit rate for the NFT with index `_nftIndex`
    function getCreditLimitRate(
        address _owner,
        uint256 _nftIndex
    ) public view returns (RateLib.Rate memory) {
        return baseCreditLimitRate;
    }

    /// @param _owner The owner of the NFT at index `_nftIndex` (or the owner of the associated position in the vault)
    /// @param _nftIndex The index of the NFT to return the liquidation limit rate for
    /// @return The liquidation limit rate for the NFT with index `_nftIndex`
    function getLiquidationLimitRate(
        address _owner,
        uint256 _nftIndex
    ) public view returns (RateLib.Rate memory) {
        return baseLiquidationLimitRate;
    }

    /// @param _owner The owner of the NFT at index `_nftIndex` (or the owner of the associated position in the vault)
    /// @param _nftIndex The index of the NFT to return the credit limit for
    /// @return The credit limit for the NFT with index `_nftIndex`, in ETH
    function getCreditLimitETH(
        address _owner,
        uint256 _nftIndex
    ) external view returns (uint256) {
        RateLib.Rate memory _creditLimitRate = getCreditLimitRate(
            _owner,
            _nftIndex
        );
        return _creditLimitRate.calculate(getNFTValueETH(_nftIndex));
    }

    /// @param _owner The owner of the NFT at index `_nftIndex` (or the owner of the associated position in the vault)
    /// @param _nftIndex The index of the NFT to return the liquidation limit for
    /// @return The liquidation limit for the NFT with index `_nftIndex`, in ETH
    function getLiquidationLimitETH(
        address _owner,
        uint256 _nftIndex
    ) external view returns (uint256) {
        RateLib.Rate memory _liquidationLimitRate = getLiquidationLimitRate(
            _owner,
            _nftIndex
        );
        return _liquidationLimitRate.calculate(getNFTValueETH(_nftIndex));
    }

    /// @return The floor value for the collection, in ETH.
    function getFloorETH() public view returns (uint256) {
        if (daoFloorOverride) {
            return overriddenFloorValueETH;
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

    /// @param _nftIndex The NFT to return the value of
    /// @return The value in ETH of the NFT at index `_nftIndex`, with 18 decimals.
    function getNFTValueETH(uint256 _nftIndex) public view returns (uint256) {
        uint256 _floor = getFloorETH();

        bytes32 _nftType = nftTypes[_nftIndex];
        if (_nftType != bytes32(0)) {
            return nftTypeValueMultiplier[_nftType].calculate(_floor);
        }

        return _floor;
    }

    /// @notice Allows the DAO to bypass the floor oracle and override the NFT floor value
    /// @param _newFloor The new floor
    function overrideFloor(
        uint256 _newFloor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newFloor == 0) revert InvalidAmount(_newFloor);
        overriddenFloorValueETH = _newFloor;
        daoFloorOverride = true;

        emit DaoFloorChanged(_newFloor);
    }

    /// @notice Allows the DAO to stop overriding floor
    function disableFloorOverride() external onlyRole(DEFAULT_ADMIN_ROLE) {
        daoFloorOverride = false;
    }

    /// @notice Allows the DAO to change the multiplier of an NFT category
    /// @param _type The category hash
    /// @param _multiplier The new multiplier
    function setNFTTypeMultiplier(
        bytes32 _type,
        RateLib.Rate calldata _multiplier
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_type == bytes32(0)) revert InvalidNFTType(_type);
        if (!_multiplier.isValid() || _multiplier.isBelowOne())
            revert RateLib.InvalidRate();
        nftTypeValueMultiplier[_type] = _multiplier;

        emit NewNFTTypeMultiplier(_type, _multiplier);
    }

    /// @notice Allows the DAO to add an NFT to a specific price category
    /// @param _nftIndexes The indexes to add to the category
    /// @param _type The category hash
    function setNFTType(
        uint256[] calldata _nftIndexes,
        bytes32 _type
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_type != bytes32(0) && nftTypeValueMultiplier[_type].numerator == 0)
            revert InvalidNFTType(_type);

        for (uint256 i; i < _nftIndexes.length; ++i) {
            nftTypes[_nftIndexes[i]] = _type;
        }
    }

    function setBaseCreditLimitRate(
        RateLib.Rate memory _baseCreditLimitRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRateBelowOne(_baseCreditLimitRate);

        baseCreditLimitRate = _baseCreditLimitRate;

        emit NewBaseCreditLimitRate(_baseCreditLimitRate);
    }

    function setBaseLiquidationLimitRate(
        RateLib.Rate memory _liquidationLimitRate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateRateBelowOne(_liquidationLimitRate);

        baseLiquidationLimitRate = _liquidationLimitRate;

        emit NewBaseLiquidationLimitRate(_liquidationLimitRate);
    }

    /// @dev Validates a rate. The denominator must be greater than zero and greater than or equal to the numerator.
    /// @param _rate The rate to validate
    function _validateRateBelowOne(RateLib.Rate memory _rate) internal pure {
        if (!_rate.isValid() || _rate.isAboveOne())
            revert RateLib.InvalidRate();
    }
}
