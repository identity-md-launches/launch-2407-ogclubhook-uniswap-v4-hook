// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    OGClubHookDeployer,
    BalanceDelta,
    PoolKey,
    SwapParams,
    TickMath,
    IPoolManager,
    StateLibrary,
    FullMath,
    Currency
} from "./helpers/HookFixture.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

contract RejectingTreasury {
    receive() external payable {
        revert("no ETH");
    }
}

contract GasBurningTreasury {
    receive() external payable {
        assembly { invalid() }
    }
}

contract ReenteringTreasury {
    OGClubHook public hook;
    bool public tried;
    bool public succeeded;

    function setHook(OGClubHook hook_) external {
        hook = hook_;
    }

    receive() external payable {
        tried = true;
        (succeeded,) = address(hook).call(abi.encodeCall(OGClubHook.flush, ()));
    }
}

contract MidUnlockFlush is IUnlockCallback {
    IPoolManager private immutable manager;
    OGClubHook private immutable hook;

    constructor(IPoolManager m, OGClubHook h) {
        manager = m;
        hook = h;
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        hook.flush();
        return "";
    }
}

contract FlushTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_flushFundsRealVaultDirectlyWithoutSelfFee() public {
        _swap(true, -10 ether);
        uint256 pending = hook.pendingFees();
        uint256 beforeVault = og.balanceOf(address(vault));
        (uint256 preview,) = hook.previewBuy();
        _ready();
        vm.recordLogs();
        (uint256 spent, uint256 out, uint256 paid) = hook.flush();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(
                logs[i].emitter == address(hook) && logs[i].topics[0] == keccak256("ClubFee(address,bool,bool,uint256)")
            );
        }
        assertEq(spent, preview);
        assertGt(out, 0);
        assertEq(og.balanceOf(address(vault)) - beforeVault, out);
        assertEq(paid, 0);
        assertEq(hook.pendingFees(), pending - spent);
        assertEq(hook.totalFees(), pending);
        _conserved(hook);
    }

    function test_flushStillPaysLpFee() public {
        _swap(true, -10 ether);
        (uint256 before0,) = manager.getFeeGrowthGlobals(key.toId());
        _ready();
        hook.flush();
        (uint256 after0,) = manager.getFeeGrowthGlobals(key.toId());
        assertGt(after0, before0);
    }

    function test_halfEthCap() public {
        _swap(true, -100 ether);
        (uint256 buy,) = hook.previewBuy();
        assertEq(buy, 0.5 ether);
        _ready();
        (uint256 spent,,) = hook.flush();
        assertEq(spent, 0.5 ether);
        assertEq(hook.pendingFees(), 0.5 ether);
        _conserved(hook);
    }

    function test_virtualReserveCap() public {
        _swap(true, -100 ether);
        _liquidity(key, -887200, 887200, -int256(990 ether));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint256 expected = FullMath.mulDiv(10 ether, 1 << 96, price) * 50 / 10000;
        (uint256 buy,) = hook.previewBuy();
        assertEq(buy, expected);
        assertLt(buy, 0.5 ether);
        _ready();
        (uint256 spent,,) = hook.flush();
        assertEq(spent, expected);
        _conserved(hook);
    }

    function test_600SecondBoundary() public {
        _swap(true, -1 ether);
        uint256 next = hook.nextFlushAt();
        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubHook.FlushTooSoon.selector, next));
        hook.flush();
        vm.warp(next);
        hook.flush();
        assertEq(hook.nextFlushAt(), next + 600);
        vm.expectRevert(abi.encodeWithSelector(OGClubHook.FlushTooSoon.selector, next + 600));
        hook.flush();
    }

    function test_tinyFeesStayClaims() public {
        _swap(true, -0.001 ether);
        uint256 claims = hook.pendingFees();
        assertLt(claims, hook.MIN_BUY_ETH());
        (uint256 buy,) = hook.previewBuy();
        assertEq(buy, 0);
        _ready();
        (uint256 spent, uint256 out,) = hook.flush();
        assertEq(spent, 0);
        assertEq(out, 0);
        assertEq(hook.pendingFees(), claims);
        _conserved(hook);
    }

    function test_exactMinimumBuys() public {
        _swap(true, -0.01 ether);
        (uint256 buy,) = hook.previewBuy();
        assertEq(buy, hook.MIN_BUY_ETH());
        _ready();
        (uint256 spent,,) = hook.flush();
        assertEq(spent, buy);
    }

    function test_zeroLiquiditySkips() public {
        _swap(true, -1 ether);
        _liquidity(key, -887200, 887200, -int256(INITIAL_LIQUIDITY));
        assertEq(manager.getLiquidity(key.toId()), 0);
        uint256 claims = hook.pendingFees();
        _ready();
        (uint256 spent, uint256 out,) = hook.flush();
        assertEq(spent, 0);
        assertEq(out, 0);
        assertEq(hook.pendingFees(), claims);
        _conserved(hook);
    }

    function test_narrowLiquidityGapPartialFlushUsesTwoPercentPriceLimit() public {
        _swap(true, -10 ether);
        _liquidity(key, -887200, 887200, -int256(INITIAL_LIQUIDITY));
        (uint160 beforePrice, int24 tick,,) = manager.getSlot0(key.toId());
        int24 lower = (tick / 200 - 1) * 200;
        // One active range then an empty gap: it runs out before spending its capped input.
        _liquidity(key, lower, lower + 200, int256(10 ether));
        (uint256 buy, uint160 limit) = hook.previewBuy();
        assertGt(buy, 0);
        _ready();
        (uint256 spent, uint256 out,) = hook.flush();
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        assertGt(spent, 0);
        assertLt(spent, buy);
        assertGt(out, 0);
        assertEq(afterPrice, limit);
        // This fixture uses sqrt price near Q96, so the squares fit uint256 exactly.
        assertGe(uint256(afterPrice) * afterPrice * 100, uint256(beforePrice) * beforePrice * 98);
        assertGe(uint256(afterPrice) * afterPrice * 102, uint256(beforePrice) * beforePrice * 100);
        assertEq(hook.pendingFees(), hook.totalFees() - spent);
        _conserved(hook);
    }

    function test_midUnlockReverts() public {
        _ready();
        MidUnlockFlush attacker = new MidUnlockFlush(manager, hook);
        vm.expectRevert(OGClubHook.MidUnlock.selector);
        attacker.go();
    }

    function test_unsolicitedUnlockCallbackReverts() public {
        vm.expectRevert();
        hook.unlockCallback(abi.encode(address(this)));
        vm.prank(address(manager));
        vm.expectRevert(OGClubHook.UnexpectedCallback.selector);
        hook.unlockCallback(abi.encode(address(this)));
    }

    function test_split5000() public {
        _checkSplit(5000);
    }

    function test_split0() public {
        _checkSplit(0);
    }

    function test_split10000() public {
        _checkSplit(10000);
    }

    function test_splitWithZeroLiquidityStillPaysClubPortion() public {
        (OGClubHook h,) = _deploy(5000, address(vault), treasury);
        _open(h, SQRT_ONE);
        PoolKey memory k = h.poolKey();
        _liquidity(k, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swapKey(k, true, -10 ether, TickMath.MIN_SQRT_PRICE + 1);
        _liquidity(k, -887200, 887200, -int256(INITIAL_LIQUIDITY));
        vm.warp(h.nextFlushAt());
        (uint256 spent, uint256 out, uint256 paid) = h.flush();
        assertEq(spent, 0);
        assertEq(out, 0);
        assertEq(paid, 0.05 ether);
        assertEq(h.pendingFees(), 0.05 ether);
        _conserved(h);
    }

    function test_splitIsAppliedToRemainingClaimsOnEachFlush() public {
        (OGClubHook h,) = _deploy(5000, address(vault), treasury);
        _open(h, SQRT_ONE);
        PoolKey memory k = h.poolKey();
        _liquidity(k, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swapKey(k, true, -200 ether, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(h.pendingFees(), 2 ether);
        vm.warp(h.nextFlushAt());
        (uint256 spent,, uint256 paid) = h.flush();
        assertEq(spent, 0.5 ether);
        assertEq(paid, 1 ether); // The buy cap does not cap the club portion.
        assertEq(h.pendingFees(), 0.5 ether);
        vm.warp(h.nextFlushAt());
        (spent,, paid) = h.flush();
        assertEq(spent, 0.25 ether);
        assertEq(paid, 0.25 ether);
        assertEq(h.pendingFees(), 0);
        _conserved(h);
    }

    function _checkSplit(uint256 bps) private {
        (OGClubHook h,) = _deploy(bps, address(vault), treasury);
        _open(h, SQRT_ONE);
        PoolKey memory k = h.poolKey();
        _liquidity(k, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swapKey(k, true, -10 ether, TickMath.MIN_SQRT_PRICE + 1);
        uint256 c = h.pendingFees();
        uint256 expectedClub = c - c * bps / 10000;
        uint256 beforeTreasury = treasury.balance;
        vm.warp(h.nextFlushAt());
        (uint256 spent, uint256 out, uint256 paid) = h.flush();
        assertEq(paid, expectedClub);
        assertEq(treasury.balance - beforeTreasury, expectedClub);
        assertEq(spent, c * bps / 10000);
        assertEq(out == 0, bps == 0);
        _conserved(h);
    }

    function test_rejectedEthDeferredAndRetriedAfterTreasuryChange() public {
        RejectingTreasury rejector = new RejectingTreasury();
        (OGClubHook h,) = _deploy(5000, address(vault), address(rejector));
        _open(h, SQRT_ONE);
        PoolKey memory k = h.poolKey();
        _liquidity(k, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swapKey(k, true, -10 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.warp(h.nextFlushAt());
        uint256 beforeVault = og.balanceOf(address(vault));
        (, uint256 out, uint256 paid) = h.flush();
        assertEq(og.balanceOf(address(vault)) - beforeVault, out);
        assertGt(out, 0);
        assertEq(paid, 0);
        assertEq(h.heldEth(), 0.05 ether);
        _conserved(h);
        vm.prank(owner);
        h.setTreasury(treasury);
        vm.warp(h.nextFlushAt());
        (,, paid) = h.flush();
        assertEq(paid, 0.05 ether);
        assertEq(h.heldEth(), 0);
        assertEq(treasury.balance, paid);
        _conserved(h);
    }

    function test_gasBurningTreasuryCannotVetoFlush() public {
        (OGClubHook h,) = _deploy(0, address(vault), address(new GasBurningTreasury()));
        _open(h, SQRT_ONE);
        PoolKey memory k = h.poolKey();
        _liquidity(k, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swapKey(k, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.warp(h.nextFlushAt());
        h.flush();
        assertEq(h.heldEth(), 0.01 ether);
        _conserved(h);
    }

    function test_treasuryReentrancyFailsButPaymentSucceeds() public {
        ReenteringTreasury recipient = new ReenteringTreasury();
        (OGClubHook h,) = _deploy(0, address(vault), address(recipient));
        recipient.setHook(h);
        _open(h, SQRT_ONE);
        PoolKey memory k = h.poolKey();
        _liquidity(k, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swapKey(k, true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.warp(h.nextFlushAt());
        h.flush();
        assertTrue(recipient.tried());
        assertFalse(recipient.succeeded());
        assertEq(address(recipient).balance, 0.01 ether);
        _conserved(h);
    }
}

import {Vm} from "forge-std/Vm.sol";
