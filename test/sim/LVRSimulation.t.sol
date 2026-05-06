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

using PoolIdLibrary for PoolKey;
using StateLibrary for IPoolManager;

/// @notice Shared LVR-simulation harness: builds pools + agents, runs a seeded price path, and
///         measures the static-vs-dynamic outcome. Carries no tests of its own so it can back both
///         the offline suite and the fork suite.
abstract contract LVRSimBase is Test, Deployers {
    LVRMinimizingFeeHook internal hook;
    ArbitrageAgent internal arb;
    RetailFlow internal retail;

    FeeCurve.Params internal feeParams = FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});
    RealizedVolatility.Config internal volCfg =
        RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18});

    int24 internal constant START_TICK = 0;
    int24 internal constant RANGE = 3000;
    uint256 internal constant SEED = 42;
    uint256 internal constant NBLOCKS = 60;
    uint24 internal stepTicks = 120; // per-block volatility of the external path; overridable

    struct RunResult {
        uint256 lpFeeValue; // LP fee revenue, valued at P=1
        int256 arbInventory; // arb net inventory value at P=1 (more negative => arb kept less)
        uint256 avgRetailFeePips; // mean fee retail was charged
    }

    /// @dev Build a local dynamic-fee pool with agents (used by the instance tests).
    function _setupLocalWorld() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        _deployHook(feeParams);
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);
        _addWideLiquidity(key);

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

    function _addWideLiquidity(PoolKey memory k) internal {
        modifyLiquidityRouter.modifyLiquidity(
            k, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0}), ZERO_BYTES
        );
    }

    function _clamp(int24 t) internal pure returns (int24) {
        if (t > RANGE) return RANGE;
        if (t < -RANGE) return -RANGE;
        return t;
    }

    /// @notice Run the identical price path + retail flow against either a fixed-fee pool (no hook)
    ///         or the dynamic-fee pool, and return LP fee revenue, the arbitrageur's net inventory,
    ///         and the average fee retail paid.
    function _run(bool dynamic) internal returns (RunResult memory res) {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        PoolKey memory k;
        if (dynamic) {
            _deployHook(feeParams);
            (k,) = initPool(currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1);
        } else {
            (k,) = initPool(currency0, currency1, IHooks(address(0)), feeParams.baseFee, 60, SQRT_PRICE_1_1);
        }
        _addWideLiquidity(k);

        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);
        ArbitrageAgent a = new ArbitrageAgent(swapRouter, manager, k, t0, t1);
        MockERC20(t0).transfer(address(a), 1e30);
        MockERC20(t1).transfer(address(a), 1e30);
        RetailFlow r = new RetailFlow(swapRouter, k, t0, t1);
        MockERC20(t0).transfer(address(r), 1e28);
        MockERC20(t1).transfer(address(r), 1e28);

        uint256 feeSum;
        for (uint256 b = 1; b <= NBLOCKS; b++) {
            vm.roll(block.number + 1);
            a.arbToTick(_clamp(PricePath.tickAt(SEED, b, START_TICK, stepTicks)));
            feeSum += dynamic ? hook.currentFee(k) : feeParams.baseFee; // fee retail faces this block
            r.noiseSwap(b);
        }

        res.arbInventory = a.inventoryValue(1e18, 1e30, 1e30);
        uint128 liq = manager.getLiquidity(k.toId());
        res.lpFeeValue = StatsCollector.lpFeeValue(manager, k.toId(), liq, 1e18);
        res.avgRetailFeePips = feeSum / NBLOCKS;
    }
}

/// @notice Offline simulation suite: exercises the LVR loop and the static-vs-dynamic comparison.
contract LVRSimulationTest is LVRSimBase {
    function setUp() public {
        _setupLocalWorld();
    }

    function test_volatilePath_buildsVarianceAndRaisesFee() public {
        for (uint256 b = 1; b <= 40; b++) {
            vm.roll(block.number + 1);
            arb.arbToTick(_clamp(PricePath.tickAt(SEED, b, START_TICK, stepTicks)));
        }
        assertGt(hook.currentVariance(key), 0);
        assertGt(hook.currentFee(key), feeParams.baseFee);
    }

    function test_retailFlow_accruesLpFees() public {
        for (uint256 b = 1; b <= 30; b++) {
            vm.roll(block.number + 1);
            arb.arbToTick(_clamp(PricePath.tickAt(SEED, b, START_TICK, stepTicks)));
            retail.noiseSwap(b);
        }
        uint128 liq = manager.getLiquidity(key.toId());
        assertGt(StatsCollector.lpFeeValue(manager, key.toId(), liq, 1e18), 0);
    }

    function test_dynamicFee_liftsLpRevenue() public {
        RunResult memory s = _run(false);
        RunResult memory d = _run(true);

        emit log_named_uint("LP fees        (static) ", s.lpFeeValue);
        emit log_named_uint("LP fees        (dynamic)", d.lpFeeValue);
        emit log_named_int("arb inventory  (static) ", s.arbInventory);
        emit log_named_int("arb inventory  (dynamic)", d.arbInventory);
        emit log_named_uint("avg retail fee (static) ", s.avgRetailFeePips);
        emit log_named_uint("avg retail fee (dynamic)", d.avgRetailFeePips);

        // On a volatile path the dynamic fee lifts LP fee revenue and leaves the arbitrageur with
        // less, at the cost of a higher average fee to retail — the tradeoff, measured, not asserted.
        assertGt(d.lpFeeValue, s.lpFeeValue);
        assertLt(d.arbInventory, s.arbInventory);
        assertGe(d.avgRetailFeePips, s.avgRetailFeePips);
    }
}
