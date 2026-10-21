// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    BalanceDelta,
    PoolKey,
    SwapParams,
    TickMath,
    IPoolManager,
    StateLibrary,
    FullMath,
    OGClubHook
} from "./helpers/HookFixture.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

contract FeesTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_buyExactEthIn() public {
        BalanceDelta delta = _swap(true, -1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(hook.pendingFees(), 0.01 ether);
        assertEq(address(hook).balance, 0);
        _conserved(hook);
    }

    function test_buyExactOgOut() public {
        BalanceDelta delta = _swap(true, 1 ether);
        assertEq(delta.amount1(), 1 ether);
        uint256 fee = hook.pendingFees();
        uint256 actualEthIn = uint256(-int256(delta.amount0())) - fee;
        assertEq(fee, actualEthIn * 100 / 9900);
        _conserved(hook);
    }

    function test_sellExactOgIn() public {
        BalanceDelta delta = _swap(false, -1 ether);
        assertEq(delta.amount1(), -1 ether);
        uint256 fee = hook.pendingFees();
        uint256 gross = uint256(int256(delta.amount0())) + fee;
        assertEq(fee, gross / 100);
        _conserved(hook);
    }

    function test_sellExactEthOut() public {
        uint256 net = 1 ether + 1;
        BalanceDelta delta = _swap(false, int256(net));
        assertEq(delta.amount0(), int256(net));
        assertEq(hook.pendingFees(), (net * 10000 + 9899) / 9900 - net);
        _conserved(hook);
    }

    function testFuzz_fourModes(uint96 raw, uint8 mode_) public {
        uint256 amount = bound(uint256(raw), 1, 50 ether);
        uint8 mode = mode_ % 4;
        BalanceDelta d = _swap(mode < 2, mode == 0 || mode == 2 ? -int256(amount) : int256(amount));
        uint256 f = hook.pendingFees();
        if (mode == 0) {
            assertEq(d.amount0(), -int256(amount));
            assertEq(f, amount / 100);
        } else if (mode == 1) {
            assertEq(d.amount1(), int256(amount));
            uint256 rawEth = uint256(-int256(d.amount0())) - f;
            assertEq(f, rawEth * 100 / 9900);
        } else if (mode == 2) {
            assertEq(d.amount1(), -int256(amount));
            assertEq(f, (uint256(int256(d.amount0())) + f) / 100);
        } else {
            assertEq(d.amount0(), int256(amount));
            assertEq(f, (amount * 10000 + 9899) / 9900 - amount);
        }
        _conserved(hook);
    }

    function test_buyEthSpecifiedPartialRevertsAndRollsBackFee() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-1);
        _expectEthPartialFill();
        _swapKey(key, true, -100 ether, limit);
        assertEq(hook.pendingFees(), 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_ONE);
    }

    function test_sellEthSpecifiedPartialRevertsAndRollsBackFee() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(1);
        _expectEthPartialFill();
        // The raw partial output exceeds the fee; router sign checks alone would not reject it.
        _swapKey(key, false, 1 ether, limit);
        assertEq(hook.pendingFees(), 0);
    }

    function _expectEthPartialFill() private {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(OGClubHook.EthPartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_ogSpecifiedPartialBuysChargeOnlyActualEth() public {
        BalanceDelta d = _swapKey(key, true, 100 ether, TickMath.getSqrtPriceAtTick(-1));
        assertLt(uint256(int256(d.amount1())), 100 ether);
        uint256 f = hook.pendingFees();
        assertEq(f, (uint256(-int256(d.amount0())) - f) * 100 / 9900);
        _conserved(hook);
    }

    function test_ogSpecifiedPartialSellsChargeOnlyActualEth() public {
        BalanceDelta d = _swapKey(key, false, -100 ether, TickMath.getSqrtPriceAtTick(1));
        assertLt(uint256(-int256(d.amount1())), 100 ether);
        uint256 f = hook.pendingFees();
        assertEq(f, (uint256(int256(d.amount0())) + f) / 100);
        _conserved(hook);
    }

    function test_ownerInitializerAndVaultHaveNoExemption() public {
        og.mint(owner, 100 ether);
        vm.deal(owner, 100 ether);
        vm.startPrank(owner, owner);
        router.swap{value: 1 ether}(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), _settings(), "");
        vm.stopPrank();
        assertEq(hook.pendingFees(), 0.01 ether);
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }
}

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
