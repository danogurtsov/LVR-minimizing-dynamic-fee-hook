// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LVRSimBase} from "../sim/LVRSimulation.t.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @notice Runs the static-vs-dynamic comparison seeded by live mainnet pools. Requires
///         `ETH_RPC_URL`; skips cleanly when it is unset (so offline CI stays green).
/// @dev The fork proves real mainnet access and reads each pool's live tick; the comparison then
///      runs each pool's volatility regime through the harness. It does not attach the hook to the
///      real pool (a v4 hook is bound at pool creation), so figures are regime-matched, not a live
///      backtest of these exact pools.
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
}
