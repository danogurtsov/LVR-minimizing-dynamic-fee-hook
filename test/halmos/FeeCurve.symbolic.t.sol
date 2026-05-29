// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../src/libraries/FeeCurve.sol";

/// @notice Symbolic spec for `FeeCurve`, to machine-prove its two guarantees over *all* inputs.
/// @dev Run with Halmos: `halmos --match-contract FeeCurveSymbolic`. The `check_` prefix is picked up
///      by Halmos (which treats the function parameters as symbolic) and ignored by `forge test`, so
///      this file adds a proof target without changing the offline suite.
contract FeeCurveSymbolic is Test {
    using FeeCurve for FeeCurve.Params;

    FeeCurve.Params internal p = FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});

    /// @dev The fee is always within [minFee, maxFee], for any variance.
    function check_feeWithinBounds(uint256 varianceWad) public view {
        uint24 f = p.fee(varianceWad);
        assertGe(f, p.minFee);
        assertLe(f, p.maxFee);
    }

    /// @dev The fee is non-decreasing in variance.
    function check_feeMonotonic(uint256 a, uint256 b) public view {
        vm.assume(a <= b);
        assertLe(p.fee(a), p.fee(b));
    }
}
