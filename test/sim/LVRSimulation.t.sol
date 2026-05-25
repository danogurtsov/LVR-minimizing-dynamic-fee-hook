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
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
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

    FeeCurve.Params internal feeParams =
        FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});
    RealizedVolatility.Config internal volCfg =
        RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18});

    int24 internal constant START_TICK = 0;
    int24 internal constant RANGE = 3000;
    uint256 internal constant SEED = 42;
    uint256 internal constant NBLOCKS = 60;
    uint24 internal stepTicks = 120; // per-block volatility of the external path; overridable
    uint256 internal feeSlope = 5e7; // fee aggressiveness (curve slope); overridable
    uint256 internal constant RETAIL_PER_BLOCK = 8; // retail-heavy flow, so volume drives LP fees

    struct RunResult {
        uint256 lpFeeValue; // LP fee revenue, valued at P=1
        int256 arbInventory; // arb net inventory value at P=1 (more negative => arb kept less)
        uint256 avgRetailFeePips; // mean fee retail was charged
        uint256 retailVolume; // total retail demand actually placed (falls as the fee deters it)
        uint256 retailFees; // fee revenue from retail (Laffer: peaks then falls with aggressiveness)
        int256 arbProfitTrue; // arb profit valued at trade-time external price = LVR extracted from LPs
        int256 lpNet; // LP welfare vs rebalancing ~= retailFees - arbProfitTrue
    }

    /// @dev External price P (token1 per token0) at `tick`, in WAD.
    function _priceWad(int24 tick) internal pure returns (uint256) {
        uint256 sp = uint256(TickMath.getSqrtPriceAtTick(tick));
        return FullMath.mulDiv(sp * sp, 1e18, 1 << 192);
    }

    /// @dev Arb the pool to `target` and return the arb's inventory gain valued at that block's
    ///      external price — the LVR extracted from LPs this block.
    function _stepArb(ArbitrageAgent a, int24 target) internal returns (int256) {
        (uint256 b0, uint256 b1) = a.balances();
        a.arbToTick(target);
        (uint256 a0, uint256 a1) = a.balances();
        int256 d0 = int256(a0) - int256(b0);
        int256 d1 = int256(a1) - int256(b1);
        return d1 + (d0 * int256(_priceWad(target))) / 1e18;
    }

    /// @dev Run the block's retail swaps and return retail's inventory gain valued at `pWad`.
    ///      (Negative: retail pays fees + impact — that value accrues to LPs.)
    function _stepRetail(RetailFlow r, uint256 b, uint24 rf, uint256 pWad) internal returns (int256) {
        (uint256 b0, uint256 b1) = r.balances();
        for (uint256 j; j < RETAIL_PER_BLOCK; j++) {
            r.noiseSwap(b * 10 + j, rf); // retail size shrinks with rf (fee-elastic)
        }
        (uint256 a0, uint256 a1) = r.balances();
        int256 d0 = int256(a0) - int256(b0);
        int256 d1 = int256(a1) - int256(b1);
        return d1 + (d0 * int256(pWad)) / 1e18;
    }

    /// @dev Build a local dynamic-fee pool with agents (used by the instance tests).
    function _setupLocalWorld() internal {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        _deployHook(feeParams);
        (key,) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
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

    uint256 internal lpCapital; // token1-value of the LP deposit at P=1, for normalizing LVR to bps

    function _addWideLiquidity(PoolKey memory k) internal {
        BalanceDelta d = modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: 0}),
            ZERO_BYTES
        );
        // delta is negative (tokens paid in); |amount0| + |amount1| at P=1 = deposited capital
        lpCapital = uint256(uint128(-d.amount0())) + uint256(uint128(-d.amount1()));
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

        FeeCurve.Params memory fp = feeParams;
        fp.slope = feeSlope;

        PoolKey memory k;
        if (dynamic) {
            _deployHook(fp);
            (k,) = initPool(
                currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, SQRT_PRICE_1_1
            );
        } else {
            (k,) = initPool(currency0, currency1, IHooks(address(0)), fp.baseFee, 60, SQRT_PRICE_1_1);
        }
        _addWideLiquidity(k);

        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);
        ArbitrageAgent a = new ArbitrageAgent(swapRouter, manager, k, t0, t1);
        MockERC20(t0).transfer(address(a), 1e30);
        MockERC20(t1).transfer(address(a), 1e30);
        RetailFlow r = new RetailFlow(swapRouter, k, t0, t1);
        MockERC20(t0).transfer(address(r), 1e30);
        MockERC20(t1).transfer(address(r), 1e30);

        uint256 feeSum;
        int256 arbGain; // arb inventory gain at trade-time external price (= LVR the arb extracts)
        int256 retailGain; // retail inventory gain at external price (negative: fees + impact to LPs)
        for (uint256 b = 1; b <= NBLOCKS; b++) {
            vm.roll(block.number + 1);
            int24 target = _clamp(PricePath.tickAt(SEED, b, START_TICK, stepTicks));
            uint256 pWad = _priceWad(target);
            arbGain += _stepArb(a, target);
            uint24 rf = dynamic ? hook.currentFee(k) : fp.baseFee; // fee retail faces this block
            feeSum += rf;
            retailGain += _stepRetail(r, b, rf, pWad);
        }

        res.arbInventory = a.inventoryValue(1e18, 1e30, 1e30);
        uint128 liq = manager.getLiquidity(k.toId());
        res.lpFeeValue = StatsCollector.lpFeeValue(manager, k.toId(), liq, 1e18);
        res.avgRetailFeePips = feeSum / NBLOCKS;
        res.retailVolume = r.totalVolume();
        res.retailFees = r.totalFeesPaid();
        res.arbProfitTrue = arbGain;
        // LP net vs rebalancing = -(value every counterparty extracts at the fair price). Fees make
        // each counterparty's gain more negative, so they raise LP net; drift/adverse-selection lowers it.
        res.lpNet = -(arbGain + retailGain);
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
            retail.noiseSwap(b, hook.currentFee(key));
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

    /// @notice The honest metric: LP welfare against a rebalancing benchmark (fees minus the LVR the
    ///         arbitrageur extracts, valued at trade-time prices) — not fee revenue.
    function test_lpNetWelfare() public {
        stepTicks = 200;
        RunResult memory s = _run(false);
        RunResult memory d = _run(true);
        emit log_named_uint("LP capital (token1 units)     ", lpCapital);
        emit log_named_int("LVR extracted, 0.1bps (static) ", _dbps(s.arbProfitTrue));
        emit log_named_int("LVR extracted, 0.1bps (dynamic)", _dbps(d.arbProfitTrue));
        emit log_named_int("LP net vs rebal, 0.1bps (static) ", _dbps(s.lpNet));
        emit log_named_int("LP net vs rebal, 0.1bps (dynamic)", _dbps(d.lpNet));
        // the dynamic fee should leave the LP better off net (shrinks the LVR the arb keeps)
        assertGt(d.lpNet, s.lpNet);
    }

    /// @dev value in tenths of a basis point of LP capital (so sub-bps signals stay visible).
    function _dbps(int256 v) internal view returns (int256) {
        return lpCapital == 0 ? int256(0) : (v * 100000) / int256(lpCapital);
    }

    /// @notice The tradeoff. Fix the volatility, crank the fee aggressiveness (curve slope), and
    ///         watch LP fee revenue rise then FALL: past an optimum, the fee scares off the retail
    ///         volume that generates fees faster than the higher rate makes up for it (a Laffer
    ///         curve). Retail volume falls monotonically the whole way — that is the cost.
    function test_feeAggressivenessSweep() public {
        stepTicks = 150; // fixed volatility regime
        uint256[6] memory slopes = [uint256(0), 2.5e7, 5e7, 1e8, 2e8, 4e8];
        uint256[6] memory arb;
        uint256[6] memory retail_;
        for (uint256 i; i < slopes.length; i++) {
            feeSlope = slopes[i];
            RunResult memory d = _run(true);
            arb[i] = d.lpFeeValue > d.retailFees ? d.lpFeeValue - d.retailFees : 0;
            retail_[i] = d.retailFees;
            emit log_named_uint("avg fee (pips)  ", d.avgRetailFeePips);
            emit log_named_uint("  arb fees (LVR) ", arb[i]);
            emit log_named_uint("  retail fees    ", retail_[i]);
            emit log_named_uint("  total LP fees  ", d.lpFeeValue);
            emit log_named_uint("  retail volume  ", d.retailVolume);
        }

        // recapture from arbitrageurs rises monotonically with the fee
        for (uint256 i = 1; i < slopes.length; i++) {
            assertGt(arb[i], arb[i - 1], "arb recapture should rise with the fee");
        }
        // retail fee revenue is a Laffer curve: it peaks at a moderate fee and then falls as the
        // fee scares off the volume that generates it
        assertGt(retail_[2], retail_[0], "retail fees should rise into the peak");
        assertGt(retail_[2], retail_[5], "retail fees should fall past the peak");
    }

    /// @notice Sweep across volatility regimes; the logged figures feed the README charts.
    function test_scenarioSweep() public {
        uint24[5] memory steps = [uint24(20), 60, 120, 200, 300];
        for (uint256 i; i < steps.length; i++) {
            stepTicks = steps[i];
            RunResult memory s = _run(false);
            RunResult memory d = _run(true);
            emit log_named_uint("step           ", steps[i]);
            emit log_named_uint("  LP static    ", s.lpFeeValue);
            emit log_named_uint("  LP dynamic   ", d.lpFeeValue);
            emit log_named_uint("  retail static ", s.avgRetailFeePips);
            emit log_named_uint("  retail dynamic", d.avgRetailFeePips);
        }
    }
}
