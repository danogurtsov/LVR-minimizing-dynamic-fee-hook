// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title RetailFlow
/// @notice Uninformed noise trades. Retail does not chase the external price; it swaps small random
///         amounts in random directions and simply pays whatever fee the hook sets. This is the flow
///         a wider fee "taxes" — the harness measures how much, so the fee's cost is not hidden.
contract RetailFlow {
    PoolSwapTest internal immutable swapRouter;
    PoolKey internal key;

    constructor(PoolSwapTest router_, PoolKey memory key_, address t0, address t1) {
        swapRouter = router_;
        key = key_;
        MockERC20(t0).approve(address(router_), type(uint256).max);
        MockERC20(t1).approve(address(router_), type(uint256).max);
    }

    /// @notice A small noise swap seeded by `seed`.
    function noiseSwap(uint256 seed) external {
        uint256 h = uint256(keccak256(abi.encode("retail", seed)));
        bool zeroForOne = (h & 1) == 0;
        uint256 amount = 1e15 + (h % 5e15); // small relative to pool depth
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }
}
