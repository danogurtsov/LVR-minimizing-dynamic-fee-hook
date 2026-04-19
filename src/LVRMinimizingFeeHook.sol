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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {FeeCurve} from "./libraries/FeeCurve.sol";
import {RealizedVolatility} from "./libraries/RealizedVolatility.sol";
import {ILVRFeeHook} from "./interfaces/ILVRFeeHook.sol";

/// @title LVRMinimizingFeeHook
/// @notice A Uniswap v4 hook that sets the LP fee from the pool's own realized volatility, so the
///         no-arbitrage band widens when loss-versus-rebalancing is highest and relaxes when the
///         market is calm. Built on OpenZeppelin's `BaseOverrideFee` (per-swap fee override) plus a
///         per-pool volatility observation updated after each swap.
/// @dev The owner can retune the curve and volatility config, and can pause to fall back to a fixed
///      fee (the floor of the curve) without ever reverting a swap.
contract LVRMinimizingFeeHook is BaseOverrideFee, Ownable2Step, Pausable, ILVRFeeHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using RealizedVolatility for RealizedVolatility.Observation;
    using FeeCurve for FeeCurve.Params;

    error InvalidAlpha();
    error InvalidMaxMove();

    FeeCurve.Params internal _feeParams;
    RealizedVolatility.Config internal _volConfig;
    mapping(PoolId => RealizedVolatility.Observation) internal _obs;

    constructor(
        IPoolManager poolManager_,
        address initialOwner,
        FeeCurve.Params memory feeParams_,
        RealizedVolatility.Config memory volConfig_
    ) BaseHook(poolManager_) Ownable(initialOwner) {
        _setFeeParams(feeParams_);
        _setVolConfig(volConfig_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    // --- owner controls -------------------------------------------------------

    /// @notice Retune the fee curve.
    function setFeeParams(FeeCurve.Params calldata feeParams_) external onlyOwner {
        _setFeeParams(feeParams_);
    }

    /// @notice Retune the volatility estimator.
    function setVolConfig(RealizedVolatility.Config calldata volConfig_) external onlyOwner {
        _setVolConfig(volConfig_);
    }

    /// @notice Pause dynamic pricing; swaps then pay a fixed fee (the curve floor). Never reverts a swap.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume dynamic pricing.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Current fee curve params.
    function feeParams() external view returns (FeeCurve.Params memory) {
        return _feeParams;
    }

    /// @notice Current volatility estimator config.
    function volConfig() external view returns (RealizedVolatility.Config memory) {
        return _volConfig;
    }

    // --- hook callbacks -------------------------------------------------------

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

    /// @dev The volatility-indexed fee: `clamp(baseFee + slope * variance, minFee, maxFee)`. When
    ///      paused, falls back to the curve floor (`minFee`) as a fixed fee.
    function _getFee(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        if (paused()) return _feeParams.minFee;
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

    // --- views ----------------------------------------------------------------

    /// @inheritdoc ILVRFeeHook
    function currentFee(PoolKey calldata key) external view returns (uint24) {
        if (paused()) return _feeParams.minFee;
        return _feeParams.fee(_obs[key.toId()].current());
    }

    /// @inheritdoc ILVRFeeHook
    function currentVariance(PoolKey calldata key) external view returns (uint256) {
        return _obs[key.toId()].current();
    }

    // --- internal -------------------------------------------------------------

    function _setFeeParams(FeeCurve.Params memory p) internal {
        p.validate();
        _feeParams = p;
        emit FeeParamsUpdated(p.baseFee, p.minFee, p.maxFee, p.slope);
    }

    function _setVolConfig(RealizedVolatility.Config memory c) internal {
        if (c.alphaWad == 0 || c.alphaWad > 1e18) revert InvalidAlpha();
        if (c.maxAbsTickMove <= 0) revert InvalidMaxMove();
        _volConfig = c;
        emit VolConfigUpdated(c.maxAbsTickMove, c.alphaWad);
    }
}
