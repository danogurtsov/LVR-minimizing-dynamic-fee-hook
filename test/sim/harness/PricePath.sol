// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PricePath
/// @notice Deterministic external-price series in tick space for the LVR simulation.
/// @dev A seeded random walk: each block the "true" market price moves by a bounded random step.
///      `stepTicks` controls volatility — small for a calm regime, large for a volatile one. The
///      same (seed, stepTicks) always yields the same path, so static- and dynamic-fee runs are
///      compared over an identical market.
library PricePath {
    /// @notice The external tick after `step` blocks, walking from `startTick`.
    function tickAt(uint256 seed, uint256 step, int24 startTick, uint24 stepTicks)
        internal
        pure
        returns (int24)
    {
        int256 tick = startTick;
        uint256 span = 2 * uint256(stepTicks) + 1;
        for (uint256 i = 1; i <= step; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            int256 delta = int256(h % span) - int256(uint256(stepTicks));
            tick += delta;
        }
        return int24(tick);
    }
}
