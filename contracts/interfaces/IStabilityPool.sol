// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IStabilityPool {
    function borrowForLiquidation(uint256 amount) external;

    function repayFromLiquidation(uint256 borrowed, uint256 repaid) external;
}
