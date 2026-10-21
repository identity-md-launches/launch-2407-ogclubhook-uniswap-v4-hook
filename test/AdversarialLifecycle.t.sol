// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    OGClubHookDeployer,
    HookSalt,
    IPoolManager,
    StateLibrary,
    PoolKey,
    PoolId,
    IHooks,
    Currency,
    SwapParams,
    BalanceDelta,
    TickMath,
    Vm
} from "./helpers/HookFixture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

contract RetryingTreasury {
    bool public rejecting = true;

    function acceptPayments() external {
        rejecting = false;
    }

    receive() external payable {
        require(!rejecting, "treasury unavailable");
    }
}

contract AdversarialLifecycleTest is HookFixture {
    using StateLibrary for IPoolManager;

    event PoolOpened(PoolId indexed poolId, uint160 sqrtPriceX96);
    event VaultFunded(address indexed caller, uint256 ethSpent, uint256 ogToVault);
    event Flushed(address indexed caller, uint256 ethSpent, uint256 ethToTreasury, uint256 remainingClaims);
    event FlushDeferred(address indexed treasury, uint256 heldEth);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);

    function test_unopenedPreviewAndFailedInitializationDoNotStartClock() public {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        (uint256 buy, uint160 limit) = h.previewBuy();
        assertEq(buy, 0);
        assertEq(limit, 0);
        assertEq(h.lastFlush(), 0);
        PoolKey memory k = h.poolKey();
        vm.prank(owner, owner);
        vm.expectRevert(); // PoolManager rejects the out-of-bounds starting price after beforeInitialize.
        manager.initialize(k, TickMath.MIN_SQRT_PRICE - 1);
        assertFalse(h.opened(), "failed initialize must roll back the gate");
        assertEq(h.lastFlush(), 0);
        (uint160 price,,,) = manager.getSlot0(k.toId());
        assertEq(price, 0);
        vm.expectEmit(true, false, false, true, address(h));
        emit PoolOpened(k.toId(), SQRT_ONE);
        _open(h, SQRT_ONE);
        assertEq(h.lastFlush(), block.timestamp);
        assertEq(h.nextFlushAt(), block.timestamp + 600);
    }

    function test_openedGateCannotBeReusedEvenByManager() public {
        vm.expectRevert(OGClubHook.AlreadyOpened.selector);
        vm.prank(address(manager), owner);
        hook.beforeInitialize(owner, key, SQRT_ONE);
    }

    function test_bothSwapCallbacksRejectEachWrongKeyField() public {
        for (uint256 field; field < 5; ++field) {
            PoolKey memory wrong = key;
            if (field == 0) wrong.currency0 = Currency.wrap(address(og));
            if (field == 1) wrong.currency1 = Currency.wrap(address(vault));
            if (field == 2) wrong.fee = 3000;
            if (field == 3) wrong.tickSpacing = 60;
            if (field == 4) wrong.hooks = IHooks(address(0));
            SwapParams memory p = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
            vm.expectRevert(OGClubHook.WrongPool.selector);
            vm.prank(address(manager));
            hook.beforeSwap(address(this), wrong, p, "");
            vm.expectRevert(OGClubHook.WrongPool.selector);
            vm.prank(address(manager));
            hook.afterSwap(address(this), wrong, p, BalanceDelta.wrap(0), "");
        }
        _conserved(hook);
    }

    function test_unopenedBeforeSwapAndUnsolicitedCallbackRejectPrecisely() public {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        PoolKey memory k = h.poolKey();
        vm.expectRevert(OGClubHook.NotOpened.selector);
        vm.prank(address(manager));
        h.beforeSwap(address(this), k, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        h.unlockCallback("");
        vm.expectRevert(OGClubHook.UnexpectedCallback.selector);
        vm.prank(address(manager));
        h.unlockCallback(""); // Reject the context before attempting to decode arbitrary data.
    }

    function test_failedOgTransferRollsBackEntireFlushAndAllowsImmediateRetry() public {
        _swap(true, -10 ether);
        _ready();
        uint256 pending = hook.pendingFees();
        uint256 last = hook.lastFlush();
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        (uint256 growthBefore,) = manager.getFeeGrowthGlobals(key.toId());
        uint256 managerEth = address(manager).balance;
        uint256 managerOg = og.balanceOf(address(manager));
        bytes memory reason = abi.encodeWithSignature("Error(string)", "blocked OG transfer");
        vm.mockCallRevert(address(og), abi.encodeWithSelector(og.transfer.selector, address(vault)), reason);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(og),
                og.transfer.selector,
                reason,
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
        hook.flush();
        vm.clearMockedCalls();
        assertEq(hook.lastFlush(), last, "failed flush must not consume cooldown");
        assertEq(hook.pendingFees(), pending, "claim burn must roll back");
        assertEq(hook.totalSpent(), 0);
        assertEq(hook.totalFlushed(), 0);
        assertEq(og.balanceOf(address(vault)), 0);
        assertEq(address(manager).balance, managerEth);
        assertEq(og.balanceOf(address(manager)), managerOg);
        (uint160 afterPrice,,,) = manager.getSlot0(key.toId());
        (uint256 growthAfter,) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(growthAfter, growthBefore);
        // No warp: both the unlock handshake and reentrancy guard must have rolled back.
        (uint256 spent, uint256 out,) = hook.flush();
        assertGt(spent, 0);
        assertGt(out, 0);
        _conserved(hook);
    }

    function test_flushEventsMatchActualBalancesAndPermissionlessCaller() public {
        _swap(true, -10 ether);
        _ready();
        address keeper = makeAddr("permissionless keeper");
        uint256 beforeVault = og.balanceOf(address(vault));
        uint256 beforeClaims = hook.pendingFees();
        vm.recordLogs();
        vm.prank(keeper);
        (uint256 spent, uint256 out, uint256 paid) = hook.flush();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 funded;
        uint256 flushed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] == keccak256("VaultFunded(address,uint256,uint256)")) {
                ++funded;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(keeper))));
                (uint256 eventSpent, uint256 eventOut) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(eventSpent, spent);
                assertEq(eventOut, og.balanceOf(address(vault)) - beforeVault);
            } else if (logs[i].topics[0] == keccak256("Flushed(address,uint256,uint256,uint256)")) {
                ++flushed;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(keeper))));
                (uint256 eventSpent, uint256 eventPaid, uint256 remaining) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(eventSpent, spent);
                assertEq(eventPaid, paid);
                assertEq(remaining, beforeClaims - spent);
            } else {
                assertTrue(false, "unexpected hook event during flush");
            }
        }
        assertEq(funded, 1);
        assertEq(flushed, 1);
        assertGt(out, 0);
        assertEq(paid, 0);
        _conserved(hook);
    }

    function test_repeatedTreasuryRejectionAccumulatesAndRetryPaysExactlyOnce() public {
        RetryingTreasury receiver = new RetryingTreasury();
        (hook,) = _deploy(0, address(vault), address(receiver));
        key = hook.poolKey();
        _open(hook, SQRT_ONE);
        _liquidity(key, -887200, 887200, int256(INITIAL_LIQUIDITY));
        for (uint256 i = 1; i <= 3; ++i) {
            _swap(true, -1 ether);
            _ready();
            vm.expectEmit(true, false, false, true, address(hook));
            emit FlushDeferred(address(receiver), i * 0.01 ether);
            (uint256 spent, uint256 out, uint256 attemptPaid) = hook.flush();
            assertEq(spent, 0);
            assertEq(out, 0);
            assertEq(attemptPaid, 0);
            assertEq(hook.pendingFees(), 0);
            assertEq(hook.heldEth(), i * 0.01 ether);
            assertEq(address(receiver).balance, 0);
            _conserved(hook);
        }
        receiver.acceptPayments();
        _ready();
        (,, uint256 paid) = hook.flush();
        assertEq(paid, 0.03 ether);
        assertEq(address(receiver).balance, paid);
        assertEq(hook.heldEth(), 0);
        _ready();
        (,, paid) = hook.flush();
        assertEq(paid, 0);
        assertEq(address(receiver).balance, 0.03 ether);
        _conserved(hook);
    }

    function test_oneWeiBelowMinimumIsRetainedUntilNewFeeReachesThreshold() public {
        uint256 threshold = hook.MIN_BUY_ETH();
        _swap(true, -int256((threshold - 1) * 100));
        (uint256 buy, uint160 limit) = hook.previewBuy();
        assertEq(buy, 0);
        assertEq(limit, 0);
        _ready();
        (uint256 spent, uint256 out,) = hook.flush();
        assertEq(spent, 0);
        assertEq(out, 0);
        assertEq(hook.pendingFees(), threshold - 1);
        _swap(true, -100);
        (buy,) = hook.previewBuy();
        assertEq(buy, threshold);
        _ready();
        (spent, out,) = hook.flush();
        assertEq(spent, threshold);
        assertGt(out, 0);
        assertEq(hook.pendingFees(), 0);
        _conserved(hook);
    }

    function test_smallOddSplitRoundsClubUpAndRetainsVaultDust() public {
        (hook,) = _deploy(5000, address(vault), treasury);
        key = hook.poolKey();
        _open(hook, SQRT_ONE);
        _liquidity(key, -887200, 887200, int256(INITIAL_LIQUIDITY));
        _swap(true, -300);
        assertEq(hook.pendingFees(), 3);
        _ready();
        (uint256 spent, uint256 out, uint256 paid) = hook.flush();
        assertEq(spent, 0);
        assertEq(out, 0);
        assertEq(paid, 2);
        assertEq(hook.pendingFees(), 1);
        _conserved(hook);
    }

    function test_treasuryChangeEventAndPendingOwnerCannotRedirectFees() public {
        (OGClubHook h,) = _deploy(5000, address(vault), treasury);
        address nextOwner = makeAddr("pending owner");
        vm.prank(owner);
        h.transferOwnership(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nextOwner));
        vm.prank(nextOwner);
        h.setTreasury(nextOwner);
        vm.expectEmit(true, true, false, true, address(h));
        emit TreasuryChanged(treasury, owner);
        vm.prank(owner);
        h.setTreasury(owner);
        vm.prank(nextOwner);
        h.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        h.setTreasury(treasury);
        vm.expectEmit(true, true, false, true, address(h));
        emit TreasuryChanged(owner, nextOwner);
        vm.prank(nextOwner);
        h.setTreasury(nextOwner);
        assertEq(h.treasury(), nextOwner);
        assertEq(h.INITIALIZER(), owner);
    }

    function test_renunciationCancelsOutstandingOwnershipOffer() public {
        address pending = makeAddr("cancelled pending owner");
        vm.startPrank(owner);
        hook.transferOwnership(pending);
        hook.renounceOwnership();
        vm.stopPrank();
        assertEq(hook.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pending));
        vm.prank(pending);
        hook.acceptOwnership();
        _swap(false, -1 ether);
        _ready();
        (, uint256 out,) = hook.flush();
        assertGt(out, 0);
        _conserved(hook);
    }
}

contract ConstructorBoundaryTest is HookFixture {
    function test_eachZeroAddressRejectedByHookAndDeployer() public {
        for (uint256 field; field < 6; ++field) {
            address[6] memory values = [address(manager), address(og), address(vault), owner, treasury, owner];
            values[field] = address(0);
            vm.expectRevert(OGClubHookDeployer.InvalidConfiguration.selector);
            new OGClubHookDeployer(
                IPoolManager(values[0]), values[1], values[2], 10_000, values[3], values[4], values[5]
            );
            bytes memory args = abi.encode(
                IPoolManager(values[0]), values[1], values[2], uint256(10_000), values[3], values[4], values[5]
            );
            bytes32 hash = keccak256(abi.encodePacked(type(OGClubHook).creationCode, args));
            (bytes32 salt, address predicted) = HookSalt.find(address(this), hash, 0, 1_000_000);
            if (field == 3) vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
            else vm.expectRevert(OGClubHook.InvalidAddress.selector);
            new OGClubHook{salt: salt}(
                IPoolManager(values[0]), values[1], values[2], 10_000, values[3], values[4], values[5]
            );
            assertEq(predicted.code.length, 0);
        }
    }

    function test_oneBasisPointStillValidatesVaultToken() public {
        address mismatchedToken = makeAddr("different token despite same symbol");
        vm.mockCall(address(vault), abi.encodeWithSignature("token()"), abi.encode(mismatchedToken));
        OGClubHookDeployer d = new OGClubHookDeployer(manager, address(og), address(vault), 1, owner, treasury, owner);
        (bytes32 salt, address expected) = HookSalt.find(address(d), d.initCodeHash(), 0, 1_000_000);
        vm.expectRevert(OGClubHook.WrongVaultToken.selector);
        d.deploy(salt, expected);
        assertEq(d.deployedHooks(salt), address(0));
        vm.clearMockedCalls();
        OGClubHook deployed = d.deploy(salt, expected);
        assertEq(deployed.VAULT_BPS(), 1);
        assertEq(address(deployed), expected);
    }

    function test_zeroSplitNeverCallsRejectingTokenGetter() public {
        vm.mockCallRevert(
            address(vault), abi.encodeWithSignature("token()"), abi.encodeWithSignature("Error(string)", "unavailable")
        );
        (OGClubHook h,) = _deploy(0, address(vault), treasury);
        assertEq(h.VAULT_BPS(), 0);
        vm.clearMockedCalls();
    }
}
