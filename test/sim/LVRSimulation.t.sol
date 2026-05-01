// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LVRMinimizingFeeHook} from "../../src/LVRMinimizingFeeHook.sol";
import {FeeCurve} from "../../src/libraries/FeeCurve.sol";
import {RealizedVolatility} from "../../src/libraries/RealizedVolatility.sol";
import {PricePath} from "./harness/PricePath.sol";
import {ArbitrageAgent} from "./harness/ArbitrageAgent.sol";
import {RetailFlow} from "./harness/RetailFlow.sol";
import {StatsCollector} from "./harness/StatsCollector.sol";

/// @notice Drives a seeded external price path against a live pool, arbitraging every block, to
///         exercise the LVR loop end-to-end. The static-vs-dynamic comparison builds on this.
contract LVRSimulationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    LVRMinimizingFeeHook internal hook;
    ArbitrageAgent internal arb;
    RetailFlow internal retail;

    FeeCurve.Params internal feeParams = FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});
    RealizedVolatility.Config internal volCfg =
        RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18});

    int24 internal constant START_TICK = 0;
    int24 internal constant RANGE = 3000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        _deployHook(feeParams);
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        _addWideLiquidity();

        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);
        arb = new ArbitrageAgent(swapRouter, manager, key, t0, t1);
        MockERC20(t0).transfer(address(arb), 1e30);
        MockERC20(t1).transfer(address(arb), 1e30);

        retail = new RetailFlow(swapRouter, key, t0, t1);
        MockERC20(t0).transfer(address(retail), 1e28);
        MockERC20(t1).transfer(address(retail), 1e28);
    }

    function _deployHook(FeeCurve.Params memory fp) internal {
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(manager, address(this), fp, volCfg);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LVRMinimizingFeeHook).creationCode, args);
        hook = new LVRMinimizingFeeHook{salt: salt}(manager, address(this), fp, volCfg);
        assertEq(address(hook), expected);
    }

    function _addWideLiquidity() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0}), ZERO_BYTES
        );
    }

    function _clamp(int24 t) internal pure returns (int24) {
        if (t > RANGE) return RANGE;
        if (t < -RANGE) return -RANGE;
        return t;
    }

    function test_volatilePath_buildsVarianceAndRaisesFee() public {
        uint256 seed = 42;
        uint24 stepTicks = 120;
        uint256 nBlocks = 40;

        for (uint256 b = 1; b <= nBlocks; b++) {
            vm.roll(block.number + 1);
            arb.arbToTick(_clamp(PricePath.tickAt(seed, b, START_TICK, stepTicks)));
        }

        assertGt(hook.currentVariance(key), 0);
        assertGt(hook.currentFee(key), feeParams.baseFee);
    }

    function test_retailFlow_accruesLpFees() public {
        for (uint256 b = 1; b <= 30; b++) {
            vm.roll(block.number + 1);
            arb.arbToTick(_clamp(PricePath.tickAt(42, b, START_TICK, 120)));
            retail.noiseSwap(b);
        }
        uint128 liq = manager.getLiquidity(key.toId());
        uint256 lpFees = StatsCollector.lpFeeValue(manager, key.toId(), liq, 1e18);
        assertGt(lpFees, 0);
    }
}
