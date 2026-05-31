// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {LVRMinimizingFeeHook} from "../../src/LVRMinimizingFeeHook.sol";
import {FeeCurve} from "../../src/libraries/FeeCurve.sol";
import {RealizedVolatility} from "../../src/libraries/RealizedVolatility.sol";

contract LVRMinimizingFeeHookTest is Test, Deployers {
    LVRMinimizingFeeHook internal hook;
    address internal owner = address(0xB0B);

    FeeCurve.Params internal feeParams =
        FeeCurve.Params({baseFee: 500, minFee: 100, maxFee: 10_000, slope: 5e7});
    RealizedVolatility.Config internal volCfg =
        RealizedVolatility.Config({maxAbsTickMove: 1000, alphaWad: 0.2e18, toxicityMode: false});

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(manager, owner, feeParams, volCfg);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(LVRMinimizingFeeHook).creationCode, args);
        hook = new LVRMinimizingFeeHook{salt: salt}(manager, owner, feeParams, volCfg);
        assertEq(address(hook), expected);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function test_initialize_requiresDynamicFee() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_startsAtBaseFee() public view {
        // no swaps yet -> zero variance -> base fee
        assertEq(hook.currentVariance(key), 0);
        assertEq(hook.currentFee(key), feeParams.baseFee);
    }

    function test_swaps_buildVariance_andRaiseFee() public {
        for (uint256 i; i < 6; i++) {
            vm.roll(block.number + 1);
            swap(key, true, -1e15, ZERO_BYTES);
            vm.roll(block.number + 1);
            swap(key, false, -1e15, ZERO_BYTES);
        }
        assertGt(hook.currentVariance(key), 0);
        assertGt(hook.currentFee(key), feeParams.baseFee); // variance pushed the fee above base
        assertLe(hook.currentFee(key), feeParams.maxFee);
    }

    function test_paused_usesFloorFee() public {
        vm.prank(owner);
        hook.pause();
        assertEq(hook.currentFee(key), feeParams.minFee);
        // and a swap still succeeds while paused
        vm.roll(block.number + 1);
        swap(key, true, -1e15, ZERO_BYTES);
    }

    function test_onlyOwner_setFeeParams() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.setFeeParams(feeParams);
    }

    function test_owner_canRetune() public {
        FeeCurve.Params memory p = FeeCurve.Params({baseFee: 800, minFee: 200, maxFee: 20_000, slope: 1e8});
        vm.prank(owner);
        hook.setFeeParams(p);
        assertEq(hook.feeParams().baseFee, 800);
    }
}
