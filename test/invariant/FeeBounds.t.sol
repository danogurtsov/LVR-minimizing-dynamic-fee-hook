// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LVRMinimizingFeeHook} from "../../src/LVRMinimizingFeeHook.sol";
import {FeeCurve} from "../../src/libraries/FeeCurve.sol";
import {RealizedVolatility} from "../../src/libraries/RealizedVolatility.sol";

/// @dev Drives random, bounded swaps and block advances against the live hook + pool.
contract SwapHandler is Test {
    PoolSwapTest internal swapRouter;
    PoolKey internal key;

    constructor(PoolSwapTest router_, PoolKey memory key_, address t0, address t1) {
        swapRouter = router_;
        key = key_;
        MockERC20(t0).approve(address(router_), type(uint256).max);
        MockERC20(t1).approve(address(router_), type(uint256).max);
    }

    function doSwap(uint256 amountSeed, bool zeroForOne) external {
        uint256 amount = bound(amountSeed, 1e12, 5e17);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    function advance(uint8 n) external {
        vm.roll(block.number + (uint256(n) % 8) + 1);
    }
}

contract FeeBoundsInvariant is Test, Deployers {
    LVRMinimizingFeeHook internal hook;
    SwapHandler internal handler;

    FeeCurve.Params internal feeParams = FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});
    RealizedVolatility.Config internal volCfg =
        RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(manager, address(this), feeParams, volCfg);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LVRMinimizingFeeHook).creationCode, args);
        hook = new LVRMinimizingFeeHook{salt: salt}(manager, address(this), feeParams, volCfg);
        assertEq(address(hook), expected);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        address t0 = Currency.unwrap(currency0);
        address t1 = Currency.unwrap(currency1);
        handler = new SwapHandler(swapRouter, key, t0, t1);
        MockERC20(t0).transfer(address(handler), 1e24);
        MockERC20(t1).transfer(address(handler), 1e24);

        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    function invariant_feeWithinBounds() public view {
        uint24 f = hook.currentFee(key);
        assertGe(f, feeParams.minFee);
        assertLe(f, feeParams.maxFee);
    }

    function invariant_varianceIsFinite() public view {
        // sanity: the estimate stays well within uint256 (no runaway accumulation)
        assertLt(hook.currentVariance(key), 1e36);
    }
}
