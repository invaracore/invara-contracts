// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Price source used by InvaraVault: returns the asset's USD price scaled to 18 decimals
interface IPriceOracle {
    function getAssetPrice(bytes32 marketId) external view returns (uint256 priceNormalized);
}
