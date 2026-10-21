// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    IPoolManager,
    TransientStateLibrary,
    StateLibrary,
    Currency,
    PoolKey,
    SwapParams,
    BalanceDelta,
    TickMath,
    Vm
} from "./helpers/HookFixture.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @notice One run is one transaction: several swaps share the manager's transient deltas.
/// This exercises flash accounting instead of opening a separate unlock for every swap.
contract AtomicSwapExecutor {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable manager;
    OGClubHook public immutable hook;

    constructor(IPoolManager m, OGClubHook h) {
        manager = m;
        hook = h;
    }

    function run(SwapParams[] calldata swaps) external returns (BalanceDelta[] memory) {
        return abi.decode(manager.unlock(abi.encode(swaps)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        SwapParams[] memory swaps = abi.decode(data, (SwapParams[]));
        PoolKey memory key = hook.poolKey();
        BalanceDelta[] memory deltas = new BalanceDelta[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            deltas[i] = manager.swap(key, swaps[i], abi.encode(i));
            require(manager.currencyDelta(address(hook), key.currency0) == 0, "unsettled hook ETH");
            require(manager.currencyDelta(address(hook), key.currency1) == 0, "unsettled hook OG");
            (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(OGClubHook.flush, ()));
            require(
                !ok && keccak256(reason) == keccak256(abi.encodeWithSelector(OGClubHook.MidUnlock.selector)),
                "flush accepted mid-transaction"
            );
        }
        _settle(key.currency0);
        _settle(key.currency1);
        require(manager.getNonzeroDeltaCount() == 0, "net settlement incomplete");
        return abi.encode(deltas);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, address(this), uint256(-delta), false);
        if (delta > 0) currency.take(manager, address(this), uint256(delta), false);
    }

    receive() external payable {}
}

contract AtomicRoutingTest is HookFixture {
    using StateLibrary for IPoolManager;
    AtomicSwapExecutor private executor;
    bytes32 private constant RAW_SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function setUp() public override {
        super.setUp();
        executor = new AtomicSwapExecutor(manager, hook);
        vm.deal(address(executor), 1_000 ether);
        og.mint(address(executor), 1_000 ether);
        _ready();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fourModesShareOneUnlockAndSettleOnlyNetDebt(uint96 raw, bool reverse) public {
        uint256 amount = bound(uint256(raw), 1, 1 ether);
        SwapParams[] memory swaps = new SwapParams[](4);
        for (uint256 i; i < 4; ++i) {
            uint256 mode = reverse ? 3 - i : i;
            swaps[i] = SwapParams(
                mode < 2,
                mode == 0 || mode == 2 ? -int256(amount) : int256(amount),
                mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            );
        }
        uint256 beforeEth = address(executor).balance;
        uint256 beforeOg = og.balanceOf(address(executor));
        vm.recordLogs();
        BalanceDelta[] memory deltas = executor.run(swaps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 index;
        uint256 expectedFees;
        int256 netEth;
        int256 netOg;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != RAW_SWAP) continue;
            (int128 rawEth,,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            uint256 mode = reverse ? 3 - index : index;
            uint256 fee;
            if (mode == 0) fee = amount / 100;
            else if (mode == 1) fee = uint256(-int256(rawEth)) / 99;
            else if (mode == 2) fee = uint256(int256(rawEth)) / 100;
            else fee = amount / 99 + (amount % 99 == 0 ? 0 : 1);
            assertEq(int256(deltas[index].amount0()), int256(rawEth) - int256(fee));
            expectedFees += fee;
            netEth += int256(deltas[index].amount0());
            netOg += int256(deltas[index].amount1());
            ++index;
        }
        assertEq(index, 4);
        assertEq(int256(address(executor).balance) - int256(beforeEth), netEth);
        assertEq(int256(og.balanceOf(address(executor))) - int256(beforeOg), netOg);
        assertEq(hook.pendingFees(), expectedFees);
        _conserved(hook);
        hook.flush(); // Same timestamp: rejected in-unlock calls must not consume the interval.
        _conserved(hook);
    }

    function test_latePartialFillRevertsEarlierSwapsAndAllFeeMintsInTheBatch() public {
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        swaps[1] = SwapParams(false, 10 ether, TickMath.getSqrtPriceAtTick(1));
        uint256 beforeEth = address(executor).balance;
        uint256 beforeOg = og.balanceOf(address(executor));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(OGClubHook.EthPartialFill.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        executor.run(swaps);
        assertEq(address(executor).balance, beforeEth);
        assertEq(og.balanceOf(address(executor)), beforeOg);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.totalFees(), 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_ONE);
        _conserved(hook);
        // A later, valid transaction must not inherit transient debts from the reverted batch.
        swaps[1].sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1;
        executor.run(swaps);
        assertGt(hook.pendingFees(), 0);
        _conserved(hook);
    }
}

import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
