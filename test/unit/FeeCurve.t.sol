// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCurve} from "../../src/libraries/FeeCurve.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

contract FeeCurveTest is Test {
    using FeeCurve for FeeCurve.Params;

    // baseFee 0.05%, floor 0.01%, cap 1.00%, slope 1e6 pips per unit variance.
    function _params() internal pure returns (FeeCurve.Params memory) {
        return FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 1e6});
    }

    function test_zeroVariance_isBaseFee() public pure {
        assertEq(_params().fee(0), 500);
    }

    function test_linearRegion() public pure {
        // extra = slope * v / WAD = 1e6 * 2e15 / 1e18 = 2000 pips; 500 + 2000 = 2500.
        assertEq(_params().fee(2e15), 2500);
    }

    function test_clampedToMax() public pure {
        assertEq(_params().fee(1e18), 10_000); // extra would be 1e6 pips, far past the cap
    }

    function test_neverBelowMin() public pure {
        FeeCurve.Params memory p = FeeCurve.Params({baseFee: 100, minFee: 100, maxFee: 10_000, slope: 0});
        assertEq(p.fee(0), 100);
    }

    function testFuzz_withinBounds(uint256 v) public pure {
        uint24 f = _params().fee(v);
        assertGe(f, 100);
        assertLe(f, 10_000);
    }

    function testFuzz_monotonic(uint256 a, uint256 b) public pure {
        if (a > b) (a, b) = (b, a);
        assertLe(_params().fee(a), _params().fee(b));
    }

    // external wrapper so `vm.expectRevert` sees the revert at a lower call depth
    function ext_validate(FeeCurve.Params memory p) external pure {
        p.validate();
    }

    function test_validate_ok() public view {
        this.ext_validate(_params());
    }

    function test_validate_minAboveBase() public {
        FeeCurve.Params memory p = FeeCurve.Params({baseFee: 100, minFee: 200, maxFee: 10_000, slope: 0});
        vm.expectRevert(FeeCurve.MinAboveBase.selector);
        this.ext_validate(p);
    }

    function test_validate_baseAboveMax() public {
        FeeCurve.Params memory p = FeeCurve.Params({baseFee: 20_000, minFee: 100, maxFee: 10_000, slope: 0});
        vm.expectRevert(FeeCurve.BaseAboveMax.selector);
        this.ext_validate(p);
    }

    function test_validate_maxTooLarge() public {
        FeeCurve.Params memory p =
            FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: LPFeeLibrary.MAX_LP_FEE + 1, slope: 0});
        vm.expectRevert(FeeCurve.MaxTooLarge.selector);
        this.ext_validate(p);
    }
}
