// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture, OGClubHook, IPoolManager, StateLibrary, FullMath, TickMath} from "./helpers/HookFixture.sol";

/// @notice The time-weighted reference used by flush, checked against a segment model built only from
/// PoolManager reads taken at each observation point (every external swap and every flush). Liquidity
/// changes are not observations: between two observations a segment earns its starting price and the
/// smaller of the liquidity seen at its two ends; the open segment ends at the current liquidity.
contract ReferenceStateTest is HookFixture {
    using StateLibrary for IPoolManager;

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant EXTRA_RANGE = 887200;

    // Segment model of the window since the last flush.
    uint256 private mWindowStart;
    uint256 private mPriceSum;
    uint256 private mLiquiditySum;
    uint256 private mObsTime;
    uint160 private mObsPrice;
    uint128 private mObsLiquidity;
    uint256 private extraLiquidity;

    function setUp() public override {
        super.setUp();
        // Opening observed the price at the opening second with no liquidity recorded yet.
        mWindowStart = block.timestamp;
        mObsTime = block.timestamp;
        mObsPrice = SQRT_ONE;
        mObsLiquidity = 0;
    }

    function _spot() private view returns (uint160 p) {
        (p,,,) = manager.getSlot0(key.toId());
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _modelObserve() private {
        uint128 liquidity = manager.getLiquidity(key.toId());
        uint256 dt = block.timestamp - mObsTime;
        if (dt != 0) {
            mPriceSum += uint256(mObsPrice) * dt;
            mLiquiditySum += _min(mObsLiquidity, liquidity) * dt;
            mObsTime = block.timestamp;
        }
        mObsPrice = _spot();
        mObsLiquidity = liquidity;
    }

    function _modelReference() private view returns (uint160, uint128) {
        uint256 window = block.timestamp - mWindowStart;
        if (window == 0) return (0, 0);
        uint256 dt = block.timestamp - mObsTime;
        uint256 open = _min(mObsLiquidity, manager.getLiquidity(key.toId()));
        return (uint160((mPriceSum + uint256(mObsPrice) * dt) / window), uint128((mLiquiditySum + open * dt) / window));
    }

    function _assertReference() private view {
        (uint160 ep, uint128 el) = _modelReference();
        (uint160 rp, uint128 rl) = hook.referenceState();
        assertEq(rp, ep, "reference price");
        assertEq(rl, el, "reference liquidity");
    }

    function _modelSwap(bool zeroForOne, int256 amount) private {
        _swap(zeroForOne, amount);
        _modelObserve();
    }

    function _modelFlush() private returns (uint256 spent) {
        _modelObserve(); // the callback observes before sizing the buy
        (uint256 preview, uint160 limit) = hook.previewBuy();
        (spent,,) = hook.flush();
        assertLe(spent, preview, "flush never spends more than the same-second preview");
        if (spent != 0) assertGe(_spot(), limit, "flush swap stopped at its price limit");
        if (preview == 0) assertEq(spent, 0);
        _modelObserve(); // and again after its own swap, which bypasses afterSwap
        mWindowStart = block.timestamp;
        mPriceSum = 0;
        mLiquiditySum = 0;
        assertEq(hook.lastFlush(), block.timestamp);
    }

    /// @dev Liquidity present only at the end of the opening window earns nothing for it: the opening
    /// recorded zero, so a full window with no swap leaves the reference depth at zero and nothing is bought.
    function test_liquidityNeverSeenBySwapEarnsNoDepth() public {
        _ready();
        (uint160 rp, uint128 rl) = hook.referenceState();
        assertEq(rp, SQRT_ONE);
        assertEq(rl, 0, "opening observed no liquidity");
        (uint256 buy, uint160 limit) = hook.previewBuy();
        assertEq(buy, 0);
        assertEq(limit, 0);
        _assertReference();
    }

    /// @dev Removing liquidity after the last swap lowers the open segment at once: the smaller end counts.
    function test_liquidityRemovedAfterLastSwapIsChargedToTheWholeGap() public {
        _modelSwap(true, -10 ether);
        vm.warp(block.timestamp + 300);
        _liquidity(key, -887200, 887200, -int256(INITIAL_LIQUIDITY / 2));
        _assertReference();
        (, uint128 rl) = hook.referenceState();
        assertEq(rl, INITIAL_LIQUIDITY / 2, "the whole 300 s gap counts only the remaining half");
        vm.warp(hook.nextFlushAt());
        (uint256 buy,) = hook.previewBuy();
        uint256 cap = FullMath.mulDiv(INITIAL_LIQUIDITY / 2, Q96, _spot()) * 50 / 10_000;
        assertEq(buy, _min(_min(hook.pendingFees(), cap), 0.5 ether));
        _modelFlush();
        _assertReference();
    }

    /// @dev Liquidity added after the last swap earns nothing until a later observation also shows it.
    function test_addedLiquidityEarnsOnlyFromItsFirstObservation() public {
        _modelSwap(true, -10 ether);
        vm.warp(block.timestamp + 200);
        _liquidity(key, -887200, 887200, int256(INITIAL_LIQUIDITY * 9));
        _assertReference();
        (, uint128 rl) = hook.referenceState();
        assertEq(rl, INITIAL_LIQUIDITY, "unobserved addition does not raise depth");
        _modelSwap(false, -1 ether); // observes the tenfold depth
        vm.warp(block.timestamp + 400);
        _assertReference();
        (, rl) = hook.referenceState();
        assertEq(rl, (INITIAL_LIQUIDITY * 200 + INITIAL_LIQUIDITY * 10 * 400) / 600);
        _modelFlush();
    }

    /// @dev A price moved more than the 2% tolerance below the window's reference is not bought into, even when
    /// it came from ordinary trading earlier in the same second as the flush; the window still restarts and
    /// the vault's share remains as claims for the next one.
    function test_flushSkipsBuyWhenSpotIsFarBelowReferenceAndRestartsWindow() public {
        _modelSwap(true, -10 ether);
        _ready();
        _modelSwap(true, -50 ether);
        (uint160 rp,) = hook.referenceState();
        assertLt(uint256(_spot()) * 1e18, uint256(rp) * 990147542976674310, "spot is beyond 2% of reference");
        (uint256 buy, uint160 limit) = hook.previewBuy();
        assertEq(buy, 0);
        assertEq(limit, 0);
        uint256 claims = hook.pendingFees();
        uint256 vaultBefore = og.balanceOf(address(vault));
        assertEq(_modelFlush(), 0);
        assertEq(hook.pendingFees(), claims, "all-vault split: claims are kept for the next window");
        assertEq(og.balanceOf(address(vault)), vaultBefore);
        assertEq(hook.nextFlushAt(), block.timestamp + 600);
        // After a quiet window at the new price the reference catches up and the buy goes through.
        vm.warp(hook.nextFlushAt());
        _assertReference();
        (rp,) = hook.referenceState();
        assertEq(rp, _spot());
        assertGt(_modelFlush(), 0);
        _conserved(hook);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_referenceMatchesSegmentModel(uint256[16] memory ops) public {
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i];
            uint256 kind = op % 5;
            op /= 5;
            if (kind == 0) {
                vm.warp(block.timestamp + bound(op, 0, 400));
            } else if (kind == 1) {
                bool zeroForOne = op & 1 == 0;
                _modelSwap(zeroForOne, -int256(bound(op >> 1, 1, 30 ether)));
            } else if (kind == 2) {
                bool zeroForOne = op & 1 == 0;
                // Exact-output sells/buys of the non-ETH side and ETH side, sized well inside the pool.
                _modelSwap(zeroForOne, int256(bound(op >> 1, 1e6, 5 ether)));
            } else if (kind == 3) {
                // Whole-ether steps (the PoolModifyLiquidityTest router asserts on sub-wei token rounding), and no more
                // than the 10,000 ETH the fixture's router call forwards can settle.
                uint256 target = bound(op, 0, 4000) * 1 ether;
                int256 change = int256(target) - int256(extraLiquidity);
                if (change != 0) _liquidity(key, -int24(int256(EXTRA_RANGE)), int24(int256(EXTRA_RANGE)), change);
                extraLiquidity = target;
            } else if (block.timestamp >= hook.nextFlushAt()) {
                _modelFlush();
            } else {
                vm.expectRevert(abi.encodeWithSelector(OGClubHook.FlushTooSoon.selector, hook.nextFlushAt()));
                hook.flush();
            }
            _assertReference();
            _assertReferenceBounds();
        }
        _conserved(hook);
    }

    /// @dev The model run on a fixed sequence that reaches two buying flushes, a removal of observed depth and
    /// an addition, so the fuzz harness is known to exercise more than empty windows.
    function test_segmentModelScriptedSequenceBuysTwice() public {
        uint256[16] memory ops;
        ops[0] = 1 + 5 * (10 ether << 1); // buy, exact 10 ETH in
        ops[1] = 3 + 5 * 2000; // +2000e18 liquidity, unobserved
        ops[2] = 1 + 5 * ((1 ether << 1) | 1); // sell, exact 1 OG in: observes the added depth
        ops[3] = 5 * 400; // warp 400 s
        ops[4] = 4; // flush too soon: reverts
        ops[5] = 5 * 400;
        ops[6] = 4; // flush buys
        ops[7] = 2 + 5 * (1 ether << 1); // buy, exact 1 OG out
        ops[8] = 5 * 300;
        ops[9] = 3; // remove the added liquidity after the last observation
        ops[10] = 5 * 300;
        ops[11] = 4; // flush buys against the reduced depth
        testFuzz_referenceMatchesSegmentModel(ops);
        assertGt(hook.totalSpent(), 0);
        assertGt(og.balanceOf(address(vault)), 0);
        assertEq(hook.lastFlush(), block.timestamp);
    }

    /// @dev The time-weighted values never exceed what was actually there: depth is at most the larger of
    /// observed and current liquidity, and the reference price stays inside the representable range.
    function _assertReferenceBounds() private view {
        (uint160 rp, uint128 rl) = hook.referenceState();
        if (block.timestamp == hook.lastFlush()) {
            assertEq(rp, 0);
            assertEq(rl, 0);
            return;
        }
        assertGe(rp, TickMath.MIN_SQRT_PRICE);
        assertLe(rp, TickMath.MAX_SQRT_PRICE);
        assertLe(rl, INITIAL_LIQUIDITY + 4000 ether);
        (uint256 buy, uint160 limit) = hook.previewBuy();
        if (buy != 0) {
            uint128 depth = manager.getLiquidity(key.toId());
            if (rl < depth) depth = rl;
            uint256 cap = FullMath.mulDiv(depth, Q96, _spot()) * 50 / 10_000;
            assertLe(buy, cap, "buy within 0.5% of the smaller of spot and reference depth");
            assertLe(buy, 0.5 ether);
            assertGe(buy, hook.MIN_BUY_ETH());
            assertLt(limit, _spot());
            assertGe(uint256(limit) * 1e18, uint256(rp) * 990147542976674310, "limit no lower than 2% below reference");
            assertGe(uint256(limit) * 1e18, uint256(_spot()) * 990147542976674310, "limit no lower than 2% below spot");
        }
    }
}
