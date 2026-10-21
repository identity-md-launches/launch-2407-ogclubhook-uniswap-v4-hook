// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture, OGClubHook, IPoolManager, StateLibrary, TickMath, IERC20} from "./helpers/HookFixture.sol";
import {OpenPool} from "../script/OpenPool.s.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

/// @notice A narrowly scoped Permit2 allowance fixture. Signature permits are not exercised here.
contract PermitAllowanceFixture {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }
    mapping(address => mapping(address => mapping(address => Allowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Allowance(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = allowance[from][token][msg.sender];
        require(block.timestamp <= a.expiration && a.amount >= amount, "Permit2 allowance");
        a.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount), "transferFrom");
    }
}

contract OpenPoolTest is HookFixture {
    using StateLibrary for IPoolManager;
    PositionManager private positions;
    PermitAllowanceFixture private permit;
    OpenPool private script;

    function setUp() public override {
        super.setUp();
        permit = new PermitAllowanceFixture();
        WETH weth = new WETH();
        positions = new PositionManager(
            manager,
            IAllowanceTransfer(address(permit)),
            100_000,
            IPositionDescriptor(address(this)),
            IWETH9(address(weth))
        );
        script = new OpenPool();
        vm.deal(owner, 100 ether);
        og.mint(owner, 1_000_000_000 ether);
    }

    function test_presetAAtomicInitAndMint() public {
        _openPreset(OpenPool.Preset.A);
    }

    function test_presetBAtomicInitAndMint() public {
        _openPreset(OpenPool.Preset.B);
    }

    function test_presetCOgOnlyAtomicInitAndMint() public {
        _openPreset(OpenPool.Preset.C);
    }

    function _config(OpenPool.Preset preset) private returns (OpenPool.OpenConfig memory c) {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        c = OpenPool.OpenConfig(
            h,
            TickMath.getSqrtPriceAtTick(180000),
            TickMath.getSqrtPriceAtTick(179000),
            TickMath.getSqrtPriceAtTick(181000),
            preset == OpenPool.Preset.C ? 0 : uint128(1 ether),
            100_000_000 ether,
            block.timestamp + 900,
            preset,
            owner
        );
    }

    function _approve(uint128 amount, uint256 deadline) private {
        vm.startPrank(owner, owner);
        og.approve(address(permit), amount);
        permit.approve(address(og), address(positions), amount, uint48(deadline));
        vm.stopPrank();
    }

    function _openPreset(OpenPool.Preset preset) private {
        OpenPool.OpenConfig memory c = _config(preset);
        (bytes[] memory calls, uint128 liquidity) = script.build(c);
        _approve(c.ogMax, c.deadline);
        uint256 beforeEth = owner.balance;
        uint256 beforeOg = og.balanceOf(owner);
        uint256 tokenId = positions.nextTokenId();
        vm.prank(owner, owner);
        positions.multicall{value: c.ethMax}(calls);
        assertTrue(c.hook.opened());
        assertEq(positions.ownerOf(tokenId), owner);
        assertEq(positions.getPositionLiquidity(tokenId), liquidity);
        (uint160 actualPrice,,,) = manager.getSlot0(c.hook.POOL_ID());
        assertEq(actualPrice, c.sqrtPriceX96);
        assertLe(beforeEth - owner.balance, c.ethMax);
        assertLe(beforeOg - og.balanceOf(owner), c.ogMax);
        assertEq(address(positions).balance, 0, "unused ETH refunded");
        assertEq(c.hook.pendingFees(), 0, "LP mint has no club fee");
        if (preset == OpenPool.Preset.C) {
            assertEq(owner.balance, beforeEth);
            assertEq(manager.getLiquidity(c.hook.POOL_ID()), 0, "C starts out of range");
        } else {
            assertGt(manager.getLiquidity(c.hook.POOL_ID()), 0);
        }
    }

    function test_failedMintRollsBackPoolInitialization() public {
        OpenPool.OpenConfig memory c = _config(OpenPool.Preset.A);
        (bytes[] memory calls,) = script.build(c);
        // Missing both approvals must revert mint and initialization together.
        vm.prank(owner, owner);
        vm.expectRevert();
        positions.multicall{value: c.ethMax}(calls);
        assertFalse(c.hook.opened());
        (uint160 price,,,) = manager.getSlot0(c.hook.POOL_ID());
        assertEq(price, 0);
    }

    function test_ownerWalletMustAlsoBeInitializerOrigin() public {
        OpenPool.OpenConfig memory c = _config(OpenPool.Preset.A);
        (bytes[] memory calls,) = script.build(c);
        _approve(c.ogMax, c.deadline);
        vm.prank(owner, makeAddr("unapproved origin"));
        vm.expectRevert();
        positions.multicall{value: c.ethMax}(calls);
        assertFalse(c.hook.opened());
    }

    function test_cRejectsLivePriceThatNeedsEth() public {
        OpenPool.OpenConfig memory c = _config(OpenPool.Preset.C);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(179000);
        vm.expectRevert("C is not OG-only at live price");
        script.build(c);
    }

    function test_cRejectsEthAndExpiredDeadline() public {
        OpenPool.OpenConfig memory c = _config(OpenPool.Preset.C);
        c.ethMax = 1;
        vm.expectRevert("C requires OG only");
        script.build(c);
        c.ethMax = 0;
        c.deadline = block.timestamp - 1;
        vm.expectRevert("deadline");
        script.build(c);
    }

    function test_livePriceOutsideOwnerBandIsRefused() public {
        OpenPool.OpenConfig memory c = _config(OpenPool.Preset.A);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(181001);
        vm.expectRevert("live price outside owner band");
        script.build(c);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(178999);
        vm.expectRevert("live price outside owner band");
        script.build(c);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(181000);
        script.build(c);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(179000);
        script.build(c);
        c.minSqrtPriceX96 = 0;
        vm.expectRevert("price band");
        script.build(c);
        c.minSqrtPriceX96 = c.maxSqrtPriceX96 + 1;
        vm.expectRevert("price band");
        script.build(c);
    }

    function test_bRejectsLivePriceOutsideItsRange() public {
        OpenPool.OpenConfig memory c = _config(OpenPool.Preset.B);
        c.minSqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        c.maxSqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(187000);
        vm.expectRevert("B is not in range at live price");
        script.build(c);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(172600);
        vm.expectRevert("B is not in range at live price");
        script.build(c);
        c.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(172601);
        (, uint128 liquidity) = script.build(c);
        assertGt(liquidity, 0);
    }

    function test_namedPresetTicks() public view {
        (int24 lower, int24 upper) = script.ticks(OpenPool.Preset.A);
        assertEq(lower, -887200);
        assertEq(upper, 887200);
        (lower, upper) = script.ticks(OpenPool.Preset.B);
        assertEq(lower, 172600);
        assertEq(upper, 186600);
        (lower, upper) = script.ticks(OpenPool.Preset.C);
        assertEq(lower, 165600);
        assertEq(upper, 179400);
    }
}
