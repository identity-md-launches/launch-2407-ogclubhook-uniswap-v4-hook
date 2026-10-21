// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    PoolKey,
    IHooks,
    IPoolManager,
    StateLibrary,
    BalanceDelta,
    SwapParams,
    TickMath,
    FullMath,
    Vm
} from "./helpers/HookFixture.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Compare actual swaps to a separate, otherwise identical v4 pool without a hook.
/// The reference delta is measured before looking at the hook's claims or return values.
abstract contract FeeOracleBase is HookFixture {
    using StateLibrary for IPoolManager;
    PoolKey internal referenceKey;
    uint128 internal activeLiquidity;

    function initialTick() internal pure virtual returns (int24);

    function setUp() public virtual override {
        super.setUp();
        uint160 price = TickMath.getSqrtPriceAtTick(initialTick());
        activeLiquidity = uint128(FullMath.mulDiv(1_000 ether, price, 1 << 96));
        if (initialTick() != 0) {
            (hook,) = _deploy(10_000, address(vault), treasury);
            key = hook.poolKey();
            _open(hook, price);
            og.mint(address(this), 1e36);
            _liquidity(key, -887200, 887200, int256(uint256(activeLiquidity)));
        }
        referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, price);
        _liquidity(referenceKey, -887200, 887200, int256(uint256(activeLiquidity)));
    }

    function _fuzzFourModes(uint96 raw, uint8 rawMode, bytes32 hookData) internal {
        uint8 mode = rawMode % 4;
        uint160 price = TickMath.getSqrtPriceAtTick(initialTick());
        uint256 reserve = mode == 0 || mode == 3
            ? FullMath.mulDiv(activeLiquidity, 1 << 96, price)
            : FullMath.mulDiv(activeLiquidity, price, 1 << 96);
        uint256 amount = bound(uint256(raw), 1, reserve / 20);
        _compare(mode, amount, abi.encode(hookData));
    }

    function test_allModesAtDustAndFeeRoundingBoundaries() public {
        uint256[10] memory amounts = [uint256(1), 2, 98, 99, 100, 101, 198, 199, 200, 10_001];
        for (uint8 mode; mode < 4; ++mode) {
            for (uint256 i; i < amounts.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                _compare(mode, amounts[i], "");
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function _compare(uint8 mode, uint256 amount, bytes memory hookData) internal {
        bool buy = mode < 2;
        bool exactInput = mode == 0 || mode == 2;
        uint256 referenceAmount = amount;
        if (mode == 0) referenceAmount -= amount / 100;
        // ceil(net * 100 / 99), written without the production multiplication/division path.
        if (mode == 3) referenceAmount += amount / 99 + (amount % 99 == 0 ? 0 : 1);
        uint160 limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta plain =
            _swapKey(referenceKey, buy, exactInput ? -int256(referenceAmount) : int256(referenceAmount), limit);
        uint256 expectedFee;
        if (mode == 0) expectedFee = amount / 100;
        else if (mode == 1) expectedFee = uint256(-int256(plain.amount0())) / 99;
        else if (mode == 2) expectedFee = uint256(int256(plain.amount0())) / 100;
        else expectedFee = referenceAmount - amount;

        uint256 ethBefore = address(this).balance;
        uint256 ogBefore = og.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta actual = router.swap{value: 10_000 ether}(
            key,
            SwapParams(buy, exactInput ? -int256(amount) : int256(amount), limit),
            PoolSwapTest.TestSettings(false, false),
            hookData
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook) && logs[i].topics[0] == keccak256("ClubFee(address,bool,bool,uint256)")
            ) {
                ++feeEvents;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(router));
                (bool eventBuy, bool eventExactIn, uint256 eventFee) = abi.decode(logs[i].data, (bool, bool, uint256));
                assertEq(eventBuy, buy);
                assertEq(eventExactIn, exactInput);
                assertEq(eventFee, expectedFee);
            }
        }
        assertEq(feeEvents, 1, "exactly one fee event, including dust");
        assertEq(int256(actual.amount0()), int256(plain.amount0()) - int256(expectedFee), "ETH delta versus oracle");
        assertEq(actual.amount1(), plain.amount1(), "club fee must not charge OG");
        assertEq(int256(address(this).balance) - int256(ethBefore), int256(actual.amount0()));
        assertEq(int256(og.balanceOf(address(this))) - int256(ogBefore), int256(actual.amount1()));
        assertEq(hook.pendingFees(), expectedFee, "fee is backed by manager claims");
        assertEq(hook.totalFees(), expectedFee);
        (uint160 p0, int24 t0, uint24 protocol0, uint24 lp0) = manager.getSlot0(key.toId());
        (uint160 p1, int24 t1, uint24 protocol1, uint24 lp1) = manager.getSlot0(referenceKey.toId());
        assertEq(p0, p1, "hook must preserve the reference price path");
        assertEq(t0, t1);
        assertEq(protocol0, protocol1);
        assertEq(lp0, 10_000);
        assertEq(lp0, lp1);
        (uint256 fee00, uint256 fee01) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 fee10, uint256 fee11) = manager.getFeeGrowthGlobals(referenceKey.toId());
        assertEq(fee00, fee10, "ETH LP fees unaffected");
        assertEq(fee01, fee11, "OG LP fees unaffected");
        _conserved(hook);
    }
}

contract FeeOracleAtParityTest is FeeOracleBase {
    function initialTick() internal pure override returns (int24) {
        return 0;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fourModesAgainstUnhookedPool(uint96 raw, uint8 mode, bytes32 data) public {
        _fuzzFourModes(raw, mode, data);
    }
}

contract FeeOracleAtOgScaleTest is FeeOracleBase {
    function initialTick() internal pure override returns (int24) {
        return 180000;
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fourModesAgainstUnhookedPool(uint96 raw, uint8 mode, bytes32 data) public {
        _fuzzFourModes(raw, mode, data);
    }
}

contract SwapFailureAtomicityTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_zeroAmountRejectedByManager() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(true, 0);
        _assertPristine();
    }

    function test_int256AndInt128BoundaryAmountsFailWithoutAccruing() public {
        int256[5] memory invalid = [
            type(int256).min,
            type(int256).max,
            int256(type(int128).min),
            int256(type(int128).max) + 1,
            -int256(type(int128).max) - 1
        ];
        for (uint256 i; i < invalid.length; ++i) {
            for (uint256 direction; direction < 2; ++direction) {
                _expectHookError(IHooks.beforeSwap.selector, OGClubHook.InvalidAmount.selector);
                _swap(direction == 0, invalid[i]);
                _assertPristine();
            }
        }
    }

    function test_sellNetThatOverflowsGrossRejected() public {
        uint256 maxNet = uint256(uint128(type(int128).max)) * 99 / 100;
        _expectHookError(IHooks.beforeSwap.selector, OGClubHook.InvalidAmount.selector);
        _swap(false, int256(maxNet + 1));
        _assertPristine();
    }

    function test_missingOgApprovalRollsBackPriceClaimsAndBalances() public {
        og.approve(address(router), 0);
        uint256 ogBefore = og.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        vm.expectRevert(); // The token rejection is wrapped by CurrencySettler's transfer helper.
        _swap(false, -1 ether);
        assertEq(og.balanceOf(address(this)), ogBefore);
        assertEq(address(this).balance, ethBefore);
        _assertPristine();
        og.approve(address(router), type(uint256).max);
        _swap(false, -1 ether);
        assertGt(hook.pendingFees(), 0, "the failed unlock must not poison the next swap");
        _conserved(hook);
    }

    function test_missingEthSettlementRollsBackBeforeSwapMint() public {
        uint256 managerBefore = address(manager).balance;
        vm.expectRevert();
        router.swap(
            key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        assertEq(address(manager).balance, managerBefore);
        _assertPristine();
        _swap(true, -1 ether);
        assertEq(hook.pendingFees(), 0.01 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ethPartialFillIsFullyAtomic(bool buy, uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1 ether, 100 ether);
        uint256 ethBefore = address(this).balance;
        uint256 ogBefore = og.balanceOf(address(this));
        _expectHookError(IHooks.afterSwap.selector, OGClubHook.EthPartialFill.selector);
        _swapKey(key, buy, buy ? -int256(amount) : int256(amount), TickMath.getSqrtPriceAtTick(buy ? -1 : int24(1)));
        assertEq(address(this).balance, ethBefore);
        assertEq(og.balanceOf(address(this)), ogBefore);
        _assertPristine();
    }

    function test_noLiquidityEthSpecifiedTradesRevert() public {
        _liquidity(key, -887200, 887200, -int256(INITIAL_LIQUIDITY));
        for (uint256 direction; direction < 2; ++direction) {
            bool buy = direction == 0;
            _expectHookError(IHooks.afterSwap.selector, OGClubHook.EthPartialFill.selector);
            _swap(buy, buy ? -int256(1 ether) : int256(1 ether));
            assertEq(hook.pendingFees(), 0);
            assertEq(hook.totalFees(), 0);
            _conserved(hook);
        }
    }

    function _assertPristine() internal view {
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.totalFees(), 0);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, SQRT_ONE);
        (uint256 g0, uint256 g1) = manager.getFeeGrowthGlobals(key.toId());
        assertEq(g0, 0);
        assertEq(g1, 0);
        _conserved(hook);
    }

    function _expectHookError(bytes4 callback, bytes4 reason) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }
}
