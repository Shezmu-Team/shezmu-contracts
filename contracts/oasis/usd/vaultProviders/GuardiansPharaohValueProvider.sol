// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import '../ERC1155ValueProvider.sol';
import '../../../libraries/AddressProvider.sol';
import '../../../interfaces/IPriceOracleAggregator.sol';
import '../../../interfaces/IGuardian.sol';

contract GuardiansPharaohValueProvider is ERC1155ValueProvider {
    AddressProvider public addressProvider;

    /// @notice This function is only called once during deployment of the proxy contract. It's not called after upgrades.
    /// @param _aggregator The NFT floor oracles aggregator
    /// @param _baseCreditLimitRate The base credit limit rate
    /// @param _baseLiquidationLimitRate The base liquidation limit rate
    function initialize(
        address _addressProvider,
        IChainlinkV3Aggregator _aggregator,
        RateLib.Rate calldata _baseCreditLimitRate,
        RateLib.Rate calldata _baseLiquidationLimitRate
    ) external initializer {
        __initialize(
            _aggregator,
            _baseCreditLimitRate,
            _baseLiquidationLimitRate
        );
        addressProvider = AddressProvider(_addressProvider);
    }

    /// @return The floor value for the collection, in USD.
    function getFloorUSD() public view override returns (uint256) {
        if (daoFloorOverride) {
            return overriddenFloorValueUSD;
        }

        uint256 mintAmount = IGuardian(addressProvider.getGuardian())
            .pricePerGuardian() * 100; // decimals 18

        uint256 shezmuPrice = IPriceOracleAggregator(
            addressProvider.getPriceOracleAggregator()
        ).viewPriceInUSD(addressProvider.getShezmu()); // decimals 6

        return (mintAmount * shezmuPrice) / 1e6;
    }
}
