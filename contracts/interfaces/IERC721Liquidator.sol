// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC721Liquidator {
    function onRepurchase(address nftVault, uint256 nftIndex) external;
}
