// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    TestOG,
    IPoolManager,
    StateLibrary,
    TransientStateLibrary,
    Currency,
    PoolKey,
    PoolId,
    SwapParams,
    ModifyLiquidityParams,
    BalanceDelta,
    TickMath,
    FullMath,
    Vm
} from "./helpers/HookFixture.sol";
import {Test} from "forge-std/Test.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract LifecycleTreasury {
    bool public rejecting;

    function reject(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        require(!rejecting, "defer treasury");
    }
}

/// @notice Only this handler is targeted. All unexpected reverts fail the campaign.
/// Ghost fee totals use PoolManager's raw Swap events, not hook.totalFees or claim deltas.
/// Unsolicited token/claim gifts are outside this fee-conservation model.
contract LifecycleHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    OGClubHook public immutable hook;
    IPoolManager public immutable manager;
    TestOG public immutable og;
    PoolSwapTest public immutable router;
    LifecycleTreasury public immutable firstTreasury;
    LifecycleTreasury public immutable secondTreasury;
    PoolKey private key;
    address[3] public actors;
    address public expectedOwner;
    address public expectedPendingOwner;
    address public expectedTreasury;
    uint256 public expectedFees;
    uint256 public observedSpent;
    uint256 public observedPaid;
    uint256 public observedVaultOg;
    uint256 public expectedHeld;
    uint256 public expectedLastFlush;
    uint256 public liquidity;
    uint256[4] public successfulModes;
    uint256 public successfulFlushes;
    uint256 public rejectedFlushes;
    uint256 public rejectedSwaps;

    bytes32 private constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    bytes32 private constant FEE_EVENT = keccak256("ClubFee(address,bool,bool,uint256)");

    constructor(OGClubHook h, TestOG token, PoolSwapTest r, LifecycleTreasury a, LifecycleTreasury b) {
        hook = h;
        manager = h.poolManager();
        og = token;
        router = r;
        firstTreasury = a;
        secondTreasury = b;
        key = h.poolKey();
        expectedOwner = h.owner();
        expectedTreasury = address(a);
        expectedLastFlush = h.lastFlush();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("lifecycle actor", i)))));
            vm.deal(actors[i], 100_000 ether);
            token.mint(actors[i], 100_000 ether);
            vm.prank(actors[i]);
            token.approve(address(r), type(uint256).max);
        }
    }

    function trade(uint96 raw, uint8 modeSeed, uint8 actorSeed, bool dust) public {
        uint8 mode = modeSeed % 4;
        address actor = actors[actorSeed % 3];
        if (liquidity == 0) {
            uint8 ethMode = mode % 2 == 0 ? 0 : 3;
            vm.expectRevert(
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(hook),
                    IHooks.afterSwap.selector,
                    abi.encodeWithSelector(OGClubHook.EthPartialFill.selector),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                )
            );
            vm.prank(actor, actor);
            router.swap{value: 1 ether}(
                key,
                SwapParams(
                    ethMode == 0,
                    ethMode == 0 ? -int256(1 ether) : int256(1 ether),
                    ethMode == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            );
            ++rejectedSwaps;
            return;
        }
        uint256 amount = bound(uint256(raw), 1, dust ? 200 : 0.1 ether);
        bool buy = mode < 2;
        bool exactInput = mode == 0 || mode == 2;
        uint256 ethBefore = actor.balance;
        uint256 ogBefore = og.balanceOf(actor);
        uint256 claimsBefore = hook.pendingFees();
        vm.recordLogs();
        vm.prank(actor, actor);
        BalanceDelta result = router.swap{value: 10 ether}(
            key,
            SwapParams(
                buy,
                exactInput ? -int256(amount) : int256(amount),
                buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            abi.encode(actorSeed)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swapEvents;
        int128 poolEth;
        int128 poolOg;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
                (poolEth, poolOg,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                ++swapEvents;
            }
        }
        assertEq(swapEvents, 1, "independent raw pool delta must be observed");
        uint256 fee;
        if (mode == 0) fee = amount / 100;
        else if (mode == 1) fee = uint256(-int256(poolEth)) / 99;
        else if (mode == 2) fee = uint256(int256(poolEth)) / 100;
        else fee = amount / 99 + (amount % 99 == 0 ? 0 : 1);
        assertEq(int256(result.amount0()), int256(poolEth) - int256(fee));
        assertEq(result.amount1(), poolOg);
        assertEq(int256(actor.balance) - int256(ethBefore), int256(result.amount0()), "trader ETH settlement");
        assertEq(int256(og.balanceOf(actor)) - int256(ogBefore), int256(result.amount1()), "trader OG settlement");
        assertEq(hook.pendingFees(), claimsBefore + fee);
        expectedFees += fee;
        ++successfulModes[mode];
    }

    function flush(uint16 elapsed, uint8 actorSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(uint256(elapsed), 0, 1200));
        uint256 nowAt = vm.getBlockTimestamp();
        uint256 next = expectedLastFlush + 600;
        address caller = actors[actorSeed % 3];
        if (nowAt < next) {
            vm.expectRevert(abi.encodeWithSelector(OGClubHook.FlushTooSoon.selector, next));
            vm.prank(caller);
            hook.flush();
            assertEq(hook.lastFlush(), expectedLastFlush, "failed flush must not reset clock");
            ++rejectedFlushes;
            return;
        }
        uint256 claimsBefore = hook.pendingFees();
        uint256 club = claimsBefore - claimsBefore * hook.VAULT_BPS() / 10_000;
        uint256 vaultBefore = og.balanceOf(hook.VAULT());
        uint256 treasuryBefore = expectedTreasury.balance;
        (uint256 preview, uint160 limit) = hook.previewBuy();
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        vm.recordLogs();
        vm.prank(caller);
        (uint256 spent, uint256 out, uint256 paid) = hook.flush();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hook)) assertTrue(logs[i].topics[0] != FEE_EVENT, "self fee");
        }
        assertEq(og.balanceOf(hook.VAULT()) - vaultBefore, out, "vault must actually receive reported OG");
        assertEq(expectedTreasury.balance - treasuryBefore, paid, "treasury must actually receive reported ETH");
        assertLe(spent, preview);
        assertLe(spent, 0.5 ether);
        if (liquidity == 0) {
            assertEq(spent, 0);
            assertEq(out, 0);
        } else {
            uint256 reserve = FullMath.mulDiv(liquidity, 1 << 96, priceBefore);
            assertLe(spent, reserve / 200, "virtual reserve cap");
            if (preview != 0) {
                (uint160 priceAfter,,,) = manager.getSlot0(key.toId());
                assertGe(priceAfter, limit, "swap exceeded limit");
                // Prices stay near Q96 in this handler, so these exact products fit uint256.
                assertGe(uint256(priceAfter) * priceAfter * 102, uint256(priceBefore) * priceBefore * 100);
            }
        }
        bool rejects = LifecycleTreasury(payable(expectedTreasury)).rejecting();
        uint256 owed = expectedHeld + club;
        assertEq(paid, rejects ? 0 : owed, "deferred debt paid exactly once");
        expectedHeld = rejects ? owed : 0;
        assertEq(hook.pendingFees(), claimsBefore - spent - club);
        observedSpent += spent;
        observedPaid += paid;
        observedVaultOg += out;
        expectedLastFlush = nowAt;
        ++successfulFlushes;
    }

    function setLiquidity(uint96 raw, bool empty) public {
        uint256 next = empty ? 0 : bound(uint256(raw), 10 ether, 1_000 ether);
        if (next == liquidity) return;
        uint256 beforeFees = hook.pendingFees();
        manager.unlock(abi.encode(int256(next) - int256(liquidity)));
        liquidity = next;
        assertEq(hook.pendingFees(), beforeFees, "LP changes must not accrue club fees");
        assertEq(manager.getLiquidity(key.toId()), liquidity);
    }

    function treasuryAction(bool useSecond, bool rejecting) public {
        LifecycleTreasury selected = useSecond ? secondTreasury : firstTreasury;
        selected.reject(rejecting);
        address caller = expectedOwner == address(0) ? actors[0] : expectedOwner;
        if (expectedOwner == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        } else if (hook.VAULT_BPS() == 10_000) {
            vm.expectRevert(OGClubHook.TreasuryDisabled.selector);
        }
        vm.prank(caller);
        hook.setTreasury(address(selected));
        if (expectedOwner != address(0) && hook.VAULT_BPS() != 10_000) expectedTreasury = address(selected);
    }

    function ownership(uint8 action, uint8 actorSeed) public {
        address actor = actors[actorSeed % 3];
        if (action % 4 == 0 && expectedOwner != address(0)) {
            vm.prank(expectedOwner);
            hook.transferOwnership(actor);
            expectedPendingOwner = actor;
        } else if (action % 4 == 1 && expectedPendingOwner != address(0)) {
            vm.prank(expectedPendingOwner);
            hook.acceptOwnership();
            expectedOwner = expectedPendingOwner;
            expectedPendingOwner = address(0);
        } else if (action % 4 == 2 && expectedOwner != address(0)) {
            vm.prank(expectedOwner);
            hook.renounceOwnership();
            expectedOwner = address(0);
            expectedPendingOwner = address(0);
        } else {
            address outsider = address(uint160(uint256(keccak256("lifecycle unauthorized"))));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
            vm.prank(outsider);
            hook.setTreasury(actor);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (BalanceDelta d,) = manager.modifyLiquidity(
            key, ModifyLiquidityParams(-887200, 887200, abi.decode(data, (int256)), bytes32(0)), ""
        );
        _settle(key.currency0, d.amount0());
        _settle(key.currency1, d.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) currency.settle(manager, address(this), uint256(-int256(delta)), false);
        if (delta > 0) currency.take(manager, address(this), uint256(int256(delta)), false);
    }

    function assertAccounting() public view {
        assertEq(
            hook.pendingFees() + expectedHeld + observedSpent + observedPaid, expectedFees, "independent conservation"
        );
        assertEq(hook.totalFees(), expectedFees);
        assertEq(hook.totalSpent(), observedSpent);
        assertEq(hook.totalFlushed(), observedPaid);
        assertEq(hook.heldEth(), expectedHeld);
        assertEq(address(hook).balance, expectedHeld);
        assertEq(address(firstTreasury).balance + address(secondTreasury).balance, observedPaid);
        assertEq(og.balanceOf(hook.VAULT()), observedVaultOg);
        assertEq(og.balanceOf(address(hook)), 0);
        assertEq(hook.owner(), expectedOwner);
        assertEq(hook.pendingOwner(), expectedPendingOwner);
        assertEq(hook.treasury(), expectedTreasury);
        assertEq(hook.lastFlush(), expectedLastFlush);
        assertEq(hook.nextFlushAt(), expectedLastFlush + 600);
        assertTrue(hook.opened());
        assertEq(manager.getLiquidity(key.toId()), liquidity);
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
    }

    receive() external payable {}
}

abstract contract LifecycleInvariantBase is HookFixture {
    LifecycleHandler internal handler;
    function split() internal pure virtual returns (uint256);

    function setUp() public override {
        super.setUp();
        LifecycleTreasury a = new LifecycleTreasury();
        LifecycleTreasury b = new LifecycleTreasury();
        (hook,) = _deploy(split(), address(vault), address(a));
        key = hook.poolKey();
        _open(hook, SQRT_ONE);
        handler = new LifecycleHandler(hook, og, router, a, b);
        vm.deal(address(handler), 1_000_000 ether);
        og.mint(address(handler), 1_000_000 ether);
        handler.setLiquidity(uint96(1_000 ether), false);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = LifecycleHandler.trade.selector;
        selectors[1] = LifecycleHandler.flush.selector;
        selectors[2] = LifecycleHandler.setLiquidity.selector;
        selectors[3] = LifecycleHandler.treasuryAction.selector;
        selectors[4] = LifecycleHandler.ownership.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _assertLifecycle() internal view {
        handler.assertAccounting();
        assertEq(hook.INITIALIZER(), owner);
        assertEq(hook.VAULT_BPS(), split());
    }

    /// @dev Deterministic coverage proves that a passing campaign is not just no-op calls.
    function test_handlerReachesAllModesDeferredPaymentZeroLiquidityAndRenunciation() public {
        for (uint8 mode; mode < 4; ++mode) {
            handler.trade(uint96(0.1 ether), mode, mode % 3, false);
        }
        handler.flush(0, 0);
        assertEq(handler.rejectedFlushes(), 1);
        handler.treasuryAction(false, true);
        handler.flush(600, 1);
        handler.setLiquidity(0, true);
        handler.trade(1, 0, 0, false);
        handler.flush(600, 2);
        handler.treasuryAction(false, false);
        handler.flush(600, 0);
        handler.setLiquidity(uint96(1_000 ether), false);
        handler.ownership(0, 1);
        handler.ownership(1, 1);
        handler.ownership(2, 0);
        handler.trade(uint96(0.1 ether), 0, 2, false);
        handler.flush(600, 2);
        handler.assertAccounting();
        for (uint8 mode; mode < 4; ++mode) {
            assertGt(handler.successfulModes(mode), 0);
        }
        assertEq(handler.rejectedSwaps(), 1);
        assertEq(handler.successfulFlushes(), 4);
        assertEq(hook.owner(), address(0));
        if (split() != 0) assertGt(handler.observedVaultOg(), 0);
        if (split() != 10_000) assertGt(handler.observedPaid(), 0);
    }
}

contract AllVaultLifecycleInvariantTest is LifecycleInvariantBase {
    function split() internal pure override returns (uint256) {
        return 10_000;
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesAndLifecycleMatchIndependentModel() public view {
        _assertLifecycle();
    }
}

contract HalfVaultLifecycleInvariantTest is LifecycleInvariantBase {
    function split() internal pure override returns (uint256) {
        return 5_000;
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesAndLifecycleMatchIndependentModel() public view {
        _assertLifecycle();
    }
}

contract AllTreasuryLifecycleInvariantTest is LifecycleInvariantBase {
    function split() internal pure override returns (uint256) {
        return 0;
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesAndLifecycleMatchIndependentModel() public view {
        _assertLifecycle();
    }
}
