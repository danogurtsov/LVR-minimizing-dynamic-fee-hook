// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {BaseOverrideFee} from "uniswap-hooks/fee/BaseOverrideFee.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {FeeCurve} from "./libraries/FeeCurve.sol";
import {RealizedVolatility} from "./libraries/RealizedVolatility.sol";
import {ILVRFeeHook} from "./interfaces/ILVRFeeHook.sol";

/// @title LVRMinimizingFeeHook
/// @notice A Uniswap v4 hook that sets the LP fee from the pool's own realized volatility, so the
///         no-arbitrage band widens when loss-versus-rebalancing is highest and relaxes when the
///         market is calm. Built on OpenZeppelin's `BaseOverrideFee` (per-swap fee override) plus a
///         per-pool volatility observation updated after each swap.
contract LVRMinimizingFeeHook is BaseOverrideFee, ILVRFeeHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using RealizedVolatility for RealizedVolatility.Observation;
    using FeeCurve for FeeCurve.Params;

    FeeCurve.Params internal _feeParams;
    RealizedVolatility.Config internal _volConfig;
    mapping(PoolId => RealizedVolatility.Observation) internal _obs;

    constructor(IPoolManager poolManager_, FeeCurve.Params memory feeParams_, RealizedVolatility.Config memory volConfig_)
        BaseHook(poolManager_)
    {
        feeParams_.validate();
        _feeParams = feeParams_;
        _volConfig = volConfig_;
        emit FeeParamsUpdated(feeParams_.baseFee, feeParams_.minFee, feeParams_.maxFee, feeParams_.slope);
        emit VolConfigUpdated(volConfig_.maxAbsTickMove, volConfig_.alphaWad);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    /// @dev Enforce a dynamic-fee pool (via `super`) and seed the volatility observation.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        bytes4 selector = super._afterInitialize(sender, key, sqrtPriceX96, tick);
        _obs[key.toId()].update(_volConfig, tick);
        return selector;
    }

    /// @dev The volatility-indexed fee: `clamp(baseFee + slope * variance, minFee, maxFee)`,
    ///      read from the current per-pool variance estimate.
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _feeParams.fee(_obs[key.toId()].current());
    }

    /// @dev Fold the post-swap tick into the pool's volatility estimate.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        _obs[key.toId()].update(_volConfig, tick);
        return (this.afterSwap.selector, int128(0));
    }

    /// @inheritdoc ILVRFeeHook
    function currentFee(PoolKey calldata key) external view returns (uint24) {
        return _feeParams.fee(_obs[key.toId()].current());
    }

    /// @inheritdoc ILVRFeeHook
    function currentVariance(PoolKey calldata key) external view returns (uint256) {
        return _obs[key.toId()].current();
    }
}
