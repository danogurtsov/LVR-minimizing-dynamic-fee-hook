// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title RetailFlow
/// @notice Uninformed noise trades — the flow a wider fee "taxes". Retail is **fee-elastic**: the
///         higher the fee it faces, the less it trades. This is what makes the fee a genuine
///         tradeoff rather than free money — raise the fee too far and the volume that generates
///         fees walks away (a Laffer curve). Demand is linear: it reaches zero at `CHOKE`.
contract RetailFlow {
    uint24 internal constant CHOKE = 10_500; // fee (pips) at which retail stops trading (just above the 1% cap)

    PoolSwapTest internal immutable swapRouter;
    PoolKey internal key;
    address internal immutable token0;
    address internal immutable token1;

    uint256 public totalVolume; // cumulative intended retail size (demand actually placed)
    uint256 public totalFeesPaid; // cumulative fee retail paid (demand * fee)

    constructor(PoolSwapTest router_, PoolKey memory key_, address t0, address t1) {
        swapRouter = router_;
        key = key_;
        token0 = t0;
        token1 = t1;
        MockERC20(t0).approve(address(router_), type(uint256).max);
        MockERC20(t1).approve(address(router_), type(uint256).max);
    }

    function balances() external view returns (uint256 b0, uint256 b1) {
        b0 = MockERC20(token0).balanceOf(address(this));
        b1 = MockERC20(token1).balanceOf(address(this));
    }

    /// @notice A noise swap whose size shrinks with the `feePips` retail is charged.
    function noiseSwap(uint256 seed, uint24 feePips) external {
        uint256 h = uint256(keccak256(abi.encode("retail", seed)));
        uint256 base = 4e16 + (h % 4e16); // baseline appetite, before the fee deters it
        uint256 demand = feePips >= CHOKE ? 0 : (base * (CHOKE - feePips)) / CHOKE;
        if (demand == 0) return;

        totalVolume += demand;
        totalFeesPaid += (demand * feePips) / 1_000_000; // pips -> fraction
        bool zeroForOne = (h & 1) == 0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(demand), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }
}
