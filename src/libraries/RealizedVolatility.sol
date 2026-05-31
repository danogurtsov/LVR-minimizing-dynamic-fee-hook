// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title RealizedVolatility
/// @notice Per-pool, on-chain estimate of return variance from the pool's own tick.
/// @dev Samples the block-over-block tick move, converts it to a log return, squares it, and
///      folds it into an exponentially-weighted moving average (EWMA) of variance (WAD, where
///      1e18 == a variance of 1.0). The per-update tick move is clamped to `maxAbsTickMove`
///      (the truncated-oracle idea) so a single manipulated swap cannot spike the estimate.
///      One sample is taken per block; intra-block swaps only update the block's closing tick.
library RealizedVolatility {
    uint256 internal constant WAD = 1e18;

    /// @dev ln(1.0001) scaled to WAD (~9.9995e13); one tick ≈ this much log return.
    int256 internal constant LOG_RETURN_PER_TICK_WAD = 99995000333308;

    struct Observation {
        bool initialized;
        int24 lastTick;
        uint32 lastBlock;
        uint256 varianceWad; // EWMA of per-block return variance (WAD) — direction-agnostic
        int256 driftWad; // EWMA of per-block *signed* return (WAD) — a directionality / toxicity proxy
    }

    /// @param maxAbsTickMove Per-block clamp on the tick delta (manipulation guard).
    /// @param alphaWad EWMA weight on the newest sample, WAD in (0, 1e18].
    /// @param toxicityMode If true, the fee should be driven by |drift|² (a directional/toxicity
    ///        signal that ignores mean-reverting noise) instead of variance.
    struct Config {
        int24 maxAbsTickMove;
        uint256 alphaWad;
        bool toxicityMode;
    }

    /// @notice Record `currentTick`, updating the variance estimate once per block.
    function update(Observation storage o, Config memory c, int24 currentTick) internal {
        uint32 nowBlock = uint32(block.number);

        if (!o.initialized) {
            o.initialized = true;
            o.lastTick = currentTick;
            o.lastBlock = nowBlock;
            return;
        }

        if (nowBlock == o.lastBlock) {
            // same block: only track the closing tick, do not add a sample
            o.lastTick = currentTick;
            return;
        }

        int256 delta = int256(currentTick) - int256(o.lastTick);
        int256 maxMove = int256(c.maxAbsTickMove);
        if (delta > maxMove) delta = maxMove;
        if (delta < -maxMove) delta = -maxMove;

        o.varianceWad = _ewma(o.varianceWad, _sampleVariance(delta), c.alphaWad);
        o.driftWad = _ewmaSigned(o.driftWad, delta * LOG_RETURN_PER_TICK_WAD, c.alphaWad);
        o.lastTick = currentTick;
        o.lastBlock = nowBlock;
    }

    /// @notice Current variance estimate (WAD).
    function current(Observation storage o) internal view returns (uint256) {
        return o.varianceWad;
    }

    /// @notice The fee-driving signal: variance, or |drift|² in toxicity mode. Variance rises for any
    ///         movement (including mean-reverting noise); |drift|² rises only for *directional* flow,
    ///         so it is meant to tax informed/toxic flow without over-taxing benign retail noise.
    function signal(Observation storage o, Config memory c) internal view returns (uint256) {
        if (!c.toxicityMode) return o.varianceWad;
        uint256 d = uint256(o.driftWad >= 0 ? o.driftWad : -o.driftWad);
        return FullMath.mulDiv(d, d, WAD);
    }

    /// @dev variance sample (WAD) = (tickDelta * lnPerTick)^2 / WAD.
    function _sampleVariance(int256 tickDelta) private pure returns (uint256) {
        int256 r = tickDelta * LOG_RETURN_PER_TICK_WAD;
        uint256 rAbs = uint256(r >= 0 ? r : -r);
        return FullMath.mulDiv(rAbs, rAbs, WAD);
    }

    /// @dev alpha*sample + (1-alpha)*prev, WAD-weighted.
    function _ewma(uint256 prev, uint256 sample, uint256 alphaWad) private pure returns (uint256) {
        uint256 a = FullMath.mulDiv(alphaWad, sample, WAD);
        uint256 b = FullMath.mulDiv(WAD - alphaWad, prev, WAD);
        return a + b;
    }

    /// @dev signed EWMA; inputs are bounded (|sample| ~ maxMove * 1e14) so plain math cannot overflow.
    function _ewmaSigned(int256 prev, int256 sample, uint256 alphaWad) private pure returns (int256) {
        int256 a = (int256(alphaWad) * sample) / int256(WAD);
        int256 b = (int256(WAD - alphaWad) * prev) / int256(WAD);
        return a + b;
    }
}
