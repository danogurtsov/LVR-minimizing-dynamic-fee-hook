// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title FeeCurve
/// @notice Maps a realized-variance estimate to a Uniswap v4 LP fee.
/// @dev The curve is `fee(v) = clamp(baseFee + slope * v, minFee, maxFee)`, where `v` is a
///      realized-variance estimate in WAD (1e18 == a variance of 1.0). The linear-in-variance
///      shape is deliberate: loss-versus-rebalancing scales with the square of volatility, so a
///      fee that is linear in *variance* tracks the cost it is meant to offset. The fee is a
///      `uint24` in pips (hundredths of a bip); 1_000_000 pips == 100%.
library FeeCurve {
    error MinAboveBase();
    error BaseAboveMax();
    error MaxTooLarge();

    uint256 internal constant WAD = 1e18;

    /// @param baseFee Fee applied at zero measured variance (pips).
    /// @param minFee  Lower clamp (pips); the fee never drops below this.
    /// @param maxFee  Upper clamp (pips); the fee never rises above this.
    /// @param slope   Pips added per 1.0 (WAD) of variance.
    struct Params {
        uint24 baseFee;
        uint24 minFee;
        uint24 maxFee;
        uint256 slope;
    }

    /// @notice Revert unless the params form a valid, monotone, in-range curve.
    function validate(Params memory p) internal pure {
        if (p.minFee > p.baseFee) revert MinAboveBase();
        if (p.baseFee > p.maxFee) revert BaseAboveMax();
        if (p.maxFee > LPFeeLibrary.MAX_LP_FEE) revert MaxTooLarge();
    }

    /// @notice Compute the LP fee (pips) for a realized-variance estimate `varianceWad`.
    /// @dev Non-decreasing in `varianceWad`; always within `[minFee, maxFee]`. The
    ///      `slope * variance` product is taken in 512 bits (FullMath), and the result is clamped
    ///      to `maxFee` (<= 1e6) before the `uint24` cast, so the cast can never truncate.
    function fee(Params memory p, uint256 varianceWad) internal pure returns (uint24) {
        uint256 extra = FullMath.mulDiv(p.slope, varianceWad, WAD);
        // Saturate before adding: baseFee and the clamp are both <= maxFee (<= 1e6), so the sum
        // below cannot overflow regardless of how large `extra` is.
        uint256 raw = p.maxFee;
        if (extra < p.maxFee) {
            raw = uint256(p.baseFee) + extra;
            if (raw > p.maxFee) raw = p.maxFee;
        }
        if (raw < p.minFee) raw = p.minFee;
        // safe: `raw` is clamped to `maxFee` (<= 1e6 < 2**24) above, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(raw);
    }
}
