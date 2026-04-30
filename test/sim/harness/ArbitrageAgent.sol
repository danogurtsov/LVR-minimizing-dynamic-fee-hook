// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title ArbitrageAgent
/// @notice The LVR mechanism: each block it moves the pool price back to the external price,
///         pocketing the difference. This is exactly the loss the hook's fee is meant to blunt —
///         a wider fee means the agent must accept a worse price to close the gap, so less value
///         leaves the pool.
contract ArbitrageAgent {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolSwapTest internal immutable swapRouter;
    IPoolManager internal immutable manager;
    address internal immutable token0;
    address internal immutable token1;
    PoolKey internal key;

    constructor(PoolSwapTest router_, IPoolManager manager_, PoolKey memory key_, address t0, address t1) {
        swapRouter = router_;
        manager = manager_;
        key = key_;
        token0 = t0;
        token1 = t1;
        MockERC20(t0).approve(address(router_), type(uint256).max);
        MockERC20(t1).approve(address(router_), type(uint256).max);
    }

    /// @notice Arbitrage the pool toward `targetTick` (the external price).
    function arbToTick(int24 targetTick) external {
        uint160 target = TickMath.getSqrtPriceAtTick(targetTick);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (current == target) return;
        bool zeroForOne = target < current;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1e27), sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {} catch {}
    }

    /// @notice Net inventory value at external price P (token1 per token0, WAD): Δ1 + Δ0 * P.
    /// @dev Compared across a matched static/dynamic run, the difference is the change in captured LVR.
    function inventoryValue(uint256 priceWad, uint256 base0, uint256 base1) external view returns (int256) {
        int256 d0 = int256(MockERC20(token0).balanceOf(address(this))) - int256(base0);
        int256 d1 = int256(MockERC20(token1).balanceOf(address(this))) - int256(base1);
        return d1 + (d0 * int256(priceWad)) / 1e18;
    }

    function balances() external view returns (uint256 b0, uint256 b1) {
        b0 = MockERC20(token0).balanceOf(address(this));
        b1 = MockERC20(token1).balanceOf(address(this));
    }
}
