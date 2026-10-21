// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    BalanceDelta,
    IPoolManager,
    StateLibrary,
    FullMath,
    SwapParams,
    ModifyLiquidityParams,
    TickMath
} from "./helpers/HookFixture.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @notice Flush sandwiches where the caller also supplies just-in-time liquidity. The flush sizes its buy
/// from the smaller of current and time-weighted active liquidity and never pays more than 2% above the
/// time-weighted price since the previous flush, so state set up inside the flush transaction cannot be
/// sold to the vault. Model: attacker starts and ends with the same OG inventory; no outside venue, gas or
/// loan costs (excluding them only strengthens the attacker).
contract JitSandwichTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint256 private constant BASE_LIQUIDITY = 10 ether; // thin pool: about 10 ETH and 10 OG at 1:1
    uint256 private constant Q96 = 1 << 96;
    address private attacker;

    function setUp() public override {
        super.setUp();
        attacker = makeAddr("jit attacker");
        // Honest volume accrues 1 ETH of claims, then the pool thins out to BASE_LIQUIDITY and a routine
        // trade observes that depth before the attacker arrives.
        _swap(true, -100 ether);
        _liquidity(key, -887200, 887200, -int256(INITIAL_LIQUIDITY - BASE_LIQUIDITY));
        _swap(false, -0.001 ether);
        _ready();
        assertGe(hook.pendingFees(), 0.5 ether);
    }

    /// @dev The reviewer's scenario: push with 3 ETH, add 100e18 liquidity around the new tick, flush,
    /// remove, sell every OG back. The hook must not buy into the pushed price.
    function test_pushAndJitLiquidityCannotLiftCapOrPrice() public {
        uint256 snapshot = vm.snapshotState();
        (uint256 honestSpent, uint256 honestOg,) = hook.flush();
        assertTrue(vm.revertToStateAndDelete(snapshot));
        assertGt(honestSpent, 0);
        assertLt(honestSpent, 0.06 ether, "cap binds near 0.5% of the real depth");

        (uint160 refBefore,) = hook.referenceState();
        vm.deal(attacker, 100 ether);
        uint256 start = attacker.balance;
        uint256 vaultBefore = og.balanceOf(address(vault));
        vm.startPrank(attacker, attacker);
        og.approve(address(router), type(uint256).max);
        og.approve(address(lp), type(uint256).max);
        _attackerSwap(true, -3 ether);
        (int24 lower, int24 upper) = _jitRange(200);
        lp.modifyLiquidity{value: 5 ether}(key, ModifyLiquidityParams(lower, upper, 100 ether, 0), "");
        (uint256 preview,) = hook.previewBuy();
        assertEq(preview, 0, "pushed spot is above the reference limit: nothing to buy");
        (uint160 refNow,) = hook.referenceState();
        assertEq(refNow, refBefore, "a push inside the transaction does not move the reference");
        (uint256 spent, uint256 out,) = hook.flush();
        lp.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -100 ether, 0), "");
        _attackerSwap(false, -int256(og.balanceOf(attacker)));
        vm.stopPrank();

        assertEq(spent, 0);
        assertEq(out, 0);
        assertEq(og.balanceOf(address(vault)), vaultBefore);
        assertEq(og.balanceOf(attacker), 0);
        assertLt(attacker.balance, start, "the attacker only paid fees");
        assertEq(honestOg > 0, true);
        _conserved(hook);
    }

    /// @dev Just-in-time liquidity at an honest price does not enlarge the buy beyond the real depth.
    function test_jitLiquidityWithoutPushDoesNotLiftReserveCap() public {
        vm.deal(attacker, 100 ether);
        og.mint(attacker, 100 ether);
        vm.startPrank(attacker, attacker);
        og.approve(address(lp), type(uint256).max);
        (int24 lower, int24 upper) = _jitRange(200);
        lp.modifyLiquidity{value: 50 ether}(key, ModifyLiquidityParams(lower, upper, 100 ether, 0), "");
        vm.stopPrank();
        (, uint128 refLiquidity) = hook.referenceState();
        assertEq(refLiquidity, BASE_LIQUIDITY);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint256 expected = FullMath.mulDiv(BASE_LIQUIDITY, Q96, price) * 50 / 10000;
        (uint256 buy,) = hook.previewBuy();
        assertEq(buy, expected);
        (uint256 spent,,) = hook.flush();
        assertEq(spent, expected);
        _conserved(hook);
    }

    /// @dev Pushes within and beyond the 2% tolerance, with JIT liquidity from 1x to 100x the real depth,
    /// in one transaction: the attacker never profits and the vault never pays more than 2% above the
    /// reference price plus the LP fee.
    function testFuzz_pushJitFlushNeverProfitable(uint16 pushBps, uint8 jitMultiple, uint8 width) public {
        _runSandwich(bound(uint256(pushBps), 10, 5000), bound(uint256(jitMultiple), 1, 100), bound(width, 1, 10), 0);
    }

    /// @dev The same attack split across two blocks: the pushed price earns only the seconds it persisted.
    function testFuzz_pushJitThenFlushNextBlockNeverProfitable(uint16 pushBps, uint8 jitMultiple) public {
        _runSandwich(bound(uint256(pushBps), 10, 5000), bound(uint256(jitMultiple), 1, 100), 1, 12);
    }

    function test_gridPushesWithTenfoldJit() public {
        for (uint256 bps = 10; bps <= 5000; bps += 50) {
            uint256 snapshot = vm.snapshotState();
            _runSandwich(bps, 10, 1, 0);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    /// @dev A price that is held for the whole window becomes the reference: the attacker must keep a
    /// mispriced quote exposed to the market for at least MIN_FLUSH_INTERVAL to move it fully.
    function test_referenceFollowsPriceOnlyWithElapsedTime() public {
        (uint160 refBefore,) = hook.referenceState();
        _swap(true, -1 ether);
        (uint160 pushed,,,) = manager.getSlot0(key.toId());
        (uint160 refSame,) = hook.referenceState();
        assertEq(refSame, refBefore);
        vm.warp(block.timestamp + 60);
        (uint160 refLater,) = hook.referenceState();
        assertLt(refLater, refBefore);
        assertGt(refLater, pushed);
        // 60 of 660 window seconds at the pushed price.
        assertApproxEqAbs(refLater, (uint256(refBefore) * 600 + uint256(pushed) * 60) / 660, 2);
        hook.flush();
        vm.warp(hook.nextFlushAt());
        (uint160 refFull,) = hook.referenceState();
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        assertEq(refFull, spot, "a full quiet window makes the held price the reference");
    }

    /// @dev Selling first lowers the price below the reference: the hook still buys, at the dip, within 2% of spot.
    function test_sellFirstStillBuysAtTheDip() public {
        og.mint(attacker, 1 ether);
        vm.startPrank(attacker, attacker);
        og.approve(address(router), type(uint256).max);
        _attackerSwap(false, -1 ether);
        vm.stopPrank();
        (uint160 spot,,,) = manager.getSlot0(key.toId());
        (uint160 refPrice,) = hook.referenceState();
        assertGt(spot, refPrice, "OG is cheaper than the reference");
        (uint256 buy, uint160 limit) = hook.previewBuy();
        assertGt(buy, 0);
        assertEq(limit, uint160(FullMath.mulDivRoundingUp(spot, 990147542976674310, 1e18)));
        (uint256 spent, uint256 out,) = hook.flush();
        assertEq(spent, buy);
        assertGt(out, 0);
    }

    function _runSandwich(uint256 pushBps, uint256 jitMultiple, uint256 widthSteps, uint256 holdSeconds) private {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint128 liquidity = manager.getLiquidity(key.toId());
        uint256 push = FullMath.mulDiv(liquidity, Q96, price) * pushBps / 10000;
        uint256 jit = BASE_LIQUIDITY * jitMultiple;
        vm.deal(attacker, 1_000 ether);
        og.mint(attacker, 1_000 ether);
        uint256 startEth = attacker.balance;
        uint256 startOg = og.balanceOf(attacker);
        uint256 vaultBefore = og.balanceOf(address(vault));

        vm.startPrank(attacker, attacker);
        og.approve(address(router), type(uint256).max);
        og.approve(address(lp), type(uint256).max);
        _attackerSwap(true, -int256(push));
        (int24 lower, int24 upper) = _jitRange(int24(int256(widthSteps)) * 200);
        lp.modifyLiquidity{value: 500 ether}(key, ModifyLiquidityParams(lower, upper, int256(jit), 0), "");
        if (holdSeconds != 0) vm.warp(block.timestamp + holdSeconds);
        // The reference the flush will use: a held push has earned exactly its seconds of weight.
        (uint160 refPrice,) = hook.referenceState();
        (uint256 spent, uint256 out,) = hook.flush();
        lp.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -int256(jit), 0), "");
        _restoreInventory(startOg);
        vm.stopPrank();

        assertEq(og.balanceOf(attacker), startOg, "attacker inventory restored");
        assertLe(attacker.balance, startEth, "profitable JIT sandwich");
        assertEq(og.balanceOf(address(vault)) - vaultBefore, out);
        if (spent != 0) {
            // OG that `spent` would buy at the reference price, before the 1% LP fee.
            uint256 ogAtReference = FullMath.mulDiv(FullMath.mulDiv(spent, refPrice, Q96), refPrice, Q96);
            assertGe(out * 10200 + 10200, ogAtReference * 9900, "vault paid more than 2% above reference");
        }
        _conserved(hook);
    }

    function _restoreInventory(uint256 target) private {
        uint256 have = og.balanceOf(attacker);
        if (have > target) {
            _attackerSwap(false, -int256(have - target));
        } else if (have < target) {
            router.swap{value: attacker.balance}(
                key,
                SwapParams(true, int256(target - have), TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
        }
    }

    function _jitRange(int24 halfWidth) private view returns (int24 lower, int24 upper) {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 aligned = (tick / 200) * 200;
        if (tick < 0 && tick % 200 != 0) aligned -= 200;
        lower = aligned - halfWidth;
        upper = aligned + 200 + halfWidth;
    }

    function _attackerSwap(bool zeroForOne, int256 amount) private returns (BalanceDelta) {
        uint256 value = zeroForOne ? uint256(-amount) : 0;
        return router.swap{value: value}(
            key,
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
