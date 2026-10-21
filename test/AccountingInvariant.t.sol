// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    PoolKey,
    BalanceDelta,
    SwapParams,
    TickMath,
    TestOG,
    IPoolManager,
    ModifyLiquidityParams
} from "./helpers/HookFixture.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract ToggleTreasury {
    bool public rejects;

    function setRejects(bool value) external {
        rejects = value;
    }

    receive() external payable {
        require(!rejects, "rejected");
    }
}

contract AccountingHandler is Test {
    using CurrencySettler for Currency;
    OGClubHook public immutable hook;
    PoolSwapTest private immutable router;
    IPoolManager private immutable manager;
    ToggleTreasury public immutable recipient;
    PoolKey private key;
    uint256 public expectedFees;
    uint256 public observedSpent;
    uint256 public observedPaid;
    uint256 public extraLiquidity;
    uint256 public swapCalls;
    uint256 public flushCalls;

    constructor(OGClubHook h, PoolSwapTest r, TestOG token, ToggleTreasury t) {
        hook = h;
        router = r;
        manager = h.poolManager();
        recipient = t;
        key = h.poolKey();
        token.approve(address(r), type(uint256).max);
    }

    function swap(uint96 raw, uint8 mode_) external {
        uint256 amount = bound(uint256(raw), 1e10, 1 ether);
        uint256 mode = mode_ % 4;
        uint256 beforeClaims = hook.pendingFees();
        BalanceDelta d = router.swap{value: 10 ether}(
            key,
            SwapParams(
                mode < 2,
                mode == 0 || mode == 2 ? -int256(amount) : int256(amount),
                mode < 2 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 fee = hook.pendingFees() - beforeClaims;
        uint256 expected;
        if (mode == 0) expected = amount / 100;
        else if (mode == 1) expected = (uint256(-int256(d.amount0())) - fee) * 100 / 9900;
        else if (mode == 2) expected = (uint256(int256(d.amount0())) + fee) / 100;
        else expected = (amount * 10000 + 9899) / 9900 - amount;
        assertEq(fee, expected);
        expectedFees += expected;
        swapCalls++;
    }

    function flush(uint16 wait) external {
        vm.warp(hook.nextFlushAt() + uint256(wait));
        (uint256 spent,, uint256 paid) = hook.flush();
        observedSpent += spent;
        observedPaid += paid;
        flushCalls++;
    }

    function rejectTreasury(bool value) external {
        recipient.setRejects(value);
    }

    function liquidity(uint96 raw, bool remove) external {
        uint256 amount = bound(uint256(raw), 1e10, 1 ether);
        if (remove) {
            if (extraLiquidity == 0) return;
            if (amount > extraLiquidity) amount = extraLiquidity;
            extraLiquidity -= amount;
        } else {
            extraLiquidity += amount;
        }
        uint256 beforeFees = hook.pendingFees();
        manager.unlock(abi.encode(remove ? -int256(amount) : int256(amount)));
        assertEq(hook.pendingFees(), beforeFees, "LP action accrued club fees");
    }

    // Unlike the upstream test LP router, permit fee credits to exceed a small new deposit.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (BalanceDelta d,) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(-887200, 887200, abi.decode(data, (int256)), 0), "");
        if (d.amount0() < 0) key.currency0.settle(manager, address(this), uint256(-int256(d.amount0())), false);
        if (d.amount1() < 0) key.currency1.settle(manager, address(this), uint256(-int256(d.amount1())), false);
        if (d.amount0() > 0) key.currency0.take(manager, address(this), uint256(int256(d.amount0())), false);
        if (d.amount1() > 0) key.currency1.take(manager, address(this), uint256(int256(d.amount1())), false);
        return "";
    }

    receive() external payable {}
}

contract AccountingInvariantTest is HookFixture {
    AccountingHandler private handler;
    ToggleTreasury private recipient;

    function setUp() public override {
        super.setUp();
        recipient = new ToggleTreasury();
        (hook,) = _deploy(5000, address(vault), address(recipient));
        _open(hook, SQRT_ONE);
        key = hook.poolKey();
        _liquidity(key, -887200, 887200, int256(INITIAL_LIQUIDITY));
        handler = new AccountingHandler(hook, router, og, recipient);
        vm.deal(address(handler), 1_000_000 ether);
        og.mint(address(handler), 1_000_000 ether);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = AccountingHandler.swap.selector;
        selectors[1] = AccountingHandler.flush.selector;
        selectors[2] = AccountingHandler.rejectTreasury.selector;
        selectors[3] = AccountingHandler.liquidity.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allFeesAccountedFor() public view {
        assertEq(
            hook.pendingFees() + hook.heldEth() + handler.observedPaid() + handler.observedSpent(),
            handler.expectedFees()
        );
        assertEq(hook.totalFees(), handler.expectedFees());
        assertEq(hook.totalSpent(), handler.observedSpent());
        assertEq(hook.totalFlushed(), handler.observedPaid());
        assertEq(address(recipient).balance, handler.observedPaid());
        _conserved(hook);
    }
}
