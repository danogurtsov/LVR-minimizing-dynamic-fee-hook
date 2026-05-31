// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {LVRMinimizingFeeHook} from "../src/LVRMinimizingFeeHook.sol";
import {FeeCurve} from "../src/libraries/FeeCurve.sol";
import {RealizedVolatility} from "../src/libraries/RealizedVolatility.sol";

/// @notice Mines a hook address whose low bits encode the permission set (afterInitialize |
///         beforeSwap | afterSwap) and deploys via the canonical CREATE2 deployer.
/// @dev Set POOL_MANAGER (and optionally HOOK_OWNER) in the environment before running.
contract Deploy is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external returns (LVRMinimizingFeeHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address owner = vm.envOr("HOOK_OWNER", msg.sender);

        // ETH/USDC-style defaults: 0.01% floor, 0.05% base, 1.00% cap.
        FeeCurve.Params memory feeParams =
            FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});
        RealizedVolatility.Config memory volConfig =
            RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18, toxicityMode: false});

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(poolManager, owner, feeParams, volConfig);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(LVRMinimizingFeeHook).creationCode, args);

        vm.startBroadcast();
        hook = new LVRMinimizingFeeHook{salt: salt}(poolManager, owner, feeParams, volConfig);
        vm.stopBroadcast();

        require(address(hook) == expected, "hook address mismatch");
        console2.log("LVRMinimizingFeeHook deployed:", address(hook));
    }
}
