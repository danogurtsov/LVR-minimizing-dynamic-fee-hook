// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RealizedVolatility} from "../../src/libraries/RealizedVolatility.sol";

contract RealizedVolatilityTest is Test {
    using RealizedVolatility for RealizedVolatility.Observation;

    RealizedVolatility.Observation internal obs;
    RealizedVolatility.Observation internal obs2;
    RealizedVolatility.Config internal cfg;

    function setUp() public {
        cfg = RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18, toxicityMode: false});
    }

    function test_firstUpdate_initializes_noVariance() public {
        obs.update(cfg, 100);
        assertTrue(obs.initialized);
        assertEq(obs.varianceWad, 0);
        assertEq(obs.lastTick, 100);
    }

    function test_sameBlock_tracksTick_noSample() public {
        obs.update(cfg, 100);
        obs.update(cfg, 300); // same block
        assertEq(obs.varianceWad, 0);
        assertEq(obs.lastTick, 300);
    }

    function test_blockAdvance_addsVariance() public {
        obs.update(cfg, 0);
        vm.roll(block.number + 1);
        obs.update(cfg, 100);
        assertGt(obs.varianceWad, 0);
        assertEq(obs.lastTick, 100);
    }

    function test_clamp_hugeMoveEqualsMaxMove() public {
        obs.update(cfg, 0);
        vm.roll(block.number + 1);
        obs.update(cfg, 100_000); // clamped to +1000

        obs2.update(cfg, 0);
        vm.roll(block.number + 1);
        obs2.update(cfg, 1000); // exactly the clamp

        assertEq(obs.varianceWad, obs2.varianceWad);
    }

    function test_ewma_convergesUpwardBoundedBySample() public {
        // one isolated sample to learn the target variance for a constant 100-tick move
        obs2.update(cfg, 0);
        vm.roll(block.number + 1);
        obs2.update(cfg, 100);
        uint256 firstStep = obs2.varianceWad; // == alpha * sample
        uint256 sample = firstStep * 5; // alpha = 0.2 => sample = firstStep / 0.2

        // feed the same 100-tick move every block; variance rises toward `sample`, never past it
        obs.update(cfg, 0);
        uint256 prev = 0;
        for (uint256 i = 0; i < 50; i++) {
            vm.roll(block.number + 1);
            int24 tick = int24(int256((i + 1) * 100));
            obs.update(cfg, tick);
            assertGt(obs.varianceWad, prev); // strictly increasing
            assertLe(obs.varianceWad, sample); // bounded by the sample
            prev = obs.varianceWad;
        }
        assertApproxEqRel(obs.varianceWad, sample, 0.01e18); // within 1% after 50 steps
    }

    function test_alphaOne_equalsLatestSample() public {
        RealizedVolatility.Config memory c =
            RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 1e18, toxicityMode: false});
        obs.update(c, 0);
        vm.roll(block.number + 1);
        obs.update(c, 500);
        uint256 v1 = obs.varianceWad;
        vm.roll(block.number + 1);
        obs.update(c, 1000); // another +500 move -> same sample
        assertEq(obs.varianceWad, v1); // alpha=1 discards history, identical move -> identical value
    }
}
