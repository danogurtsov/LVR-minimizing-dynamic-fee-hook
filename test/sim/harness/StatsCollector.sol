// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title StatsCollector
/// @notice The measurement layer for the simulation. Turns raw pool/agent state into the figures
///         that decide whether the dynamic fee actually helps: LP fee revenue, the value the
///         arbitrageur extracted (LVR proxy), and the average fee retail was charged.
/// @dev Prices are taken as token1-per-token0 in WAD. The bundled sims start and oscillate around a
///      1:1 pool, so `priceWad = 1e18` is used; the value is honest as a *matched* static-vs-dynamic
///      comparison over an identical path, not as an absolute LVR figure.
library StatsCollector {
    using StateLibrary for IPoolManager;

    struct Stats {
        uint256 lpFeeValueWad; // LP fees earned, valued at `priceWad`
        int256 arbProfitWad; // arbitrageur inventory value change (captured LVR)
        uint256 avgRetailFeePips; // mean fee retail paid across the run
        uint256 endVarianceWad; // volatility estimate at the end
    }

    /// @notice LP fees accrued to `liquidity`, valued at `priceWad` (token1 + token0 * price).
    function lpFeeValue(IPoolManager manager, PoolId id, uint128 liquidity, uint256 priceWad)
        internal
        view
        returns (uint256)
    {
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(id);
        uint256 fee0 = FullMath.mulDiv(g0, liquidity, 1 << 128);
        uint256 fee1 = FullMath.mulDiv(g1, liquidity, 1 << 128);
        return fee1 + FullMath.mulDiv(fee0, priceWad, 1e18);
    }
}
