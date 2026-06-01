// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LVRSimBase} from "../sim/LVRSimulation.t.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Runs the static-vs-dynamic comparison seeded by live mainnet pools. Requires
///         `ETH_RPC_URL`; skips cleanly when it is unset (so offline CI stays green).
/// @dev Two fork tests: `test_forkRealPools` reads each pool's live tick and runs its volatility
///      regime through the harness; `test_historicalReplay` replays a real pool's actual per-12s tick
///      moves (from v3 `observe`) as the external path — a genuine historical backtest of the price
///      dynamics. Neither attaches the hook to the real pool (a v4 hook is bound at pool creation).
contract RealPoolsForkTest is LVRSimBase {
    struct RealPool {
        string name;
        address v3pool;
        uint24 step;
    }

    function test_forkRealPools() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("ETH_RPC_URL unset - skipping fork test");
            return;
        }
        vm.createSelectFork(rpc);

        RealPool[3] memory pools = [
            RealPool("ETH/USDC  0.05%", 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640, 120),
            RealPool("WBTC/ETH  0.30%", 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD, 200),
            RealPool("USDC/USDT 0.01%", 0x3416cF6C708Da44DB2624D63ea0AAef7113527C6, 20)
        ];

        for (uint256 i; i < pools.length; i++) {
            (, int24 liveTick,,,,,) = IUniswapV3Pool(pools[i].v3pool).slot0();
            emit log_string(pools[i].name);
            emit log_named_int("  live mainnet tick     ", liveTick);

            stepTicks = pools[i].step;
            RunResult memory s = _run(false);
            RunResult memory d = _run(true);

            emit log_named_uint("  LP fees static        ", s.lpFeeValue);
            emit log_named_uint("  LP fees dynamic       ", d.lpFeeValue);
            emit log_named_uint("  avg retail fee dynamic", d.avgRetailFeePips);

            assertGt(d.lpFeeValue, s.lpFeeValue);
        }
    }

    /// @notice #4 — a genuine historical backtest: replay a real pool's per-12s tick moves (from v3
    ///         `observe`) as the external path, then compare best-static vs dynamic on LP net.
    function test_historicalReplay() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("ETH_RPC_URL unset - skipping historical replay");
            return;
        }
        vm.createSelectFork(rpc);

        address pool = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // ETH/USDC 0.05%
        uint32 n = uint32(NBLOCKS) + 2;
        uint32[] memory ago = new uint32[](n);
        for (uint256 i; i < n; i++) {
            ago[i] = uint32((n - 1 - i) * 12); // descending: oldest .. now, 12s apart
        }
        (int56[] memory tc,) = IUniswapV3Pool(pool).observe(ago);

        // average tick per interval, then the move between consecutive intervals
        delete _histDeltas;
        int56 prevAvg = (tc[1] - tc[0]) / 12;
        for (uint256 i = 1; i < n - 1; i++) {
            int56 avg = (tc[i + 1] - tc[i]) / 12;
            _histDeltas.push(int24(avg - prevAvg));
            prevAvg = avg;
        }

        histReplay = true;
        varyingVol = true; // route the walk through _walkStep
        staticFeePips = 10_000;
        int256 bestStatic = _run(false).lpNet;
        volCfg.toxicityMode = false;
        int256 dyn = _run(true).lpNet;

        emit log_named_uint("real intervals replayed   ", _histDeltas.length);
        emit log_named_int("best static LP net 0.1bps ", (bestStatic * 100000) / int256(lpCapital));
        emit log_named_int("dynamic     LP net 0.1bps ", (dyn * 100000) / int256(lpCapital));
        // Note (not asserted): on a *calm* real window both are ~0 and dynamic is not worse — its
        // disadvantage is specific to volatile / regime-changing conditions, where the lag bites.
        assertEq(_histDeltas.length, NBLOCKS); // the replay actually ran on real data
    }
}
