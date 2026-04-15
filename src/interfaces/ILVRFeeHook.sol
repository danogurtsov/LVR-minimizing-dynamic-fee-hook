// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ILVRFeeHook
/// @notice External surface of the LVR-minimizing dynamic-fee hook.
interface ILVRFeeHook {
    event FeeParamsUpdated(uint24 baseFee, uint24 minFee, uint24 maxFee, uint256 slope);
    event VolConfigUpdated(int24 maxAbsTickMove, uint256 alphaWad);

    /// @notice The LP fee (pips) the hook would apply to `key` at the current variance estimate.
    function currentFee(PoolKey calldata key) external view returns (uint24);

    /// @notice The current realized-variance estimate (WAD) for `key`.
    function currentVariance(PoolKey calldata key) external view returns (uint256);
}
