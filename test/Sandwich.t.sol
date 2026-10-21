// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    BalanceDelta,
    IPoolManager,
    StateLibrary,
    FullMath,
    SwapParams,
    TickMath
} from "./helpers/HookFixture.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Standalone sandwiches: no LP ownership, external venues, exogenous repricing, gas or loan fees.
/// Excluding gas and loan fees gives the attacker a stronger profit bound in this model.
contract SandwichTest is HookFixture {
    using StateLibrary for IPoolManager;

    function testFuzz_buyFlushSellNeverProfitable(uint16 fraction, uint96 liquidity_) public {
        uint256 bps = bound(uint256(fraction), 10, 5000); // 0.1% .. 50% of active virtual reserves.
        uint256 remainingLiquidity = bound(uint256(liquidity_), 1 ether, INITIAL_LIQUIDITY);
        _prime(remainingLiquidity);
        _sandwich(bps, true);
    }

    function testFuzz_sellFlushBuyNeverProfitable(uint16 fraction, uint96 liquidity_) public {
        uint256 bps = bound(uint256(fraction), 10, 5000);
        uint256 remainingLiquidity = bound(uint256(liquidity_), 1 ether, INITIAL_LIQUIDITY);
        _prime(remainingLiquidity);
        _sandwich(bps, false);
    }

    function test_gridPointOneThroughFiftyPercent() public {
        _prime(10 ether); // reserve cap binds, rather than the less aggressive 0.5 ETH absolute cap.
        for (uint256 bps = 10; bps <= 5000; bps += 10) {
            uint256 snapshot = vm.snapshotState();
            _sandwich(bps, true);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function _prime(uint256 remainingLiquidity) private {
        _swap(true, -100 ether); // Generate ample REAL fee claims before the attack.
        if (remainingLiquidity != INITIAL_LIQUIDITY) {
            _liquidity(key, -887200, 887200, -int256(INITIAL_LIQUIDITY - remainingLiquidity));
        }
        _ready();
    }

    function _sandwich(uint256 bps, bool buyFirst) private {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());
        address attacker = makeAddr("sandwich attacker");
        uint256 reserve =
            buyFirst ? FullMath.mulDiv(liquidity, 1 << 96, price) : FullMath.mulDiv(liquidity, price, 1 << 96);
        uint256 amount = reserve * bps / 10000;
        vm.deal(attacker, 100_000 ether);
        og.mint(attacker, buyFirst ? 0 : amount);
        uint256 beforeEth = attacker.balance;
        uint256 beforeOg = og.balanceOf(attacker);
        vm.startPrank(attacker, attacker);
        og.approve(address(router), type(uint256).max);
        BalanceDelta front = router.swap{value: buyFirst ? amount : 0}(
            key,
            SwapParams(buyFirst, -int256(amount), buyFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        hook.flush();
        if (buyFirst) {
            router.swap(
                key,
                SwapParams(false, -int256(front.amount1()), TickMath.MAX_SQRT_PRICE - 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        } else {
            router.swap{value: 10_000 ether}(
                key,
                SwapParams(true, int256(amount), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }
        vm.stopPrank();
        assertEq(og.balanceOf(attacker), beforeOg, "attacker must restore OG inventory");
        assertLe(attacker.balance, beforeEth, "profitable sandwich");
        _conserved(hook);
    }
}
