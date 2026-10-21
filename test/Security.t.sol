// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    HookFixture,
    OGClubHook,
    OGClubHookDeployer,
    OGClubFarmVault,
    IERC20,
    IPoolManager,
    PoolKey,
    Currency,
    IHooks,
    HookSalt,
    BalanceDelta,
    SwapParams,
    TickMath
} from "./helpers/HookFixture.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SecurityTest is HookFixture {
    function test_exactFlagsAndPermissions() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x20cc);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity);
        assertFalse(
            p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(hook.owner(), owner);
        assertEq(hook.INITIALIZER(), owner);
        assertEq(hook.CLUB_FEE_BPS(), 100);
        assertEq(hook.VAULT_BPS(), 10000);
    }

    function test_cannotInitializeTwice() public {
        vm.prank(owner, owner);
        vm.expectRevert();
        manager.initialize(key, SQRT_ONE);
    }

    function test_initializerGateUsesOriginThroughRouter() public {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        PoolKey memory k = h.poolKey();
        // Correct sender but wrong transaction origin fails.
        vm.prank(owner, address(this));
        vm.expectRevert();
        manager.initialize(k, SQRT_ONE);
        assertFalse(h.opened());
        // An intermediary is allowed when the configured owner is transaction origin.
        vm.prank(address(lp), owner);
        manager.initialize(k, SQRT_ONE);
        assertTrue(h.opened());
    }

    function test_wrongCurrencyFeeSpacingOrHookCannotOpen() public {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        PoolKey memory k = h.poolKey();
        k.fee = 3000;
        vm.prank(owner, owner);
        vm.expectRevert();
        manager.initialize(k, SQRT_ONE);
        k = h.poolKey();
        k.tickSpacing = 60;
        vm.prank(owner, owner);
        vm.expectRevert();
        manager.initialize(k, SQRT_ONE);
        k = h.poolKey();
        k.currency0 = Currency.wrap(address(1));
        vm.prank(owner, owner);
        vm.expectRevert();
        manager.initialize(k, SQRT_ONE);
        k = h.poolKey();
        k.currency1 = Currency.wrap(address(vault));
        vm.prank(owner, owner);
        vm.expectRevert();
        manager.initialize(k, SQRT_ONE);
        assertFalse(h.opened());
    }

    function test_callbacksRequirePoolManager() public {
        vm.expectRevert();
        hook.beforeInitialize(owner, key, SQRT_ONE);
        vm.expectRevert();
        hook.beforeSwap(owner, key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert();
        hook.afterSwap(owner, key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), BalanceDelta.wrap(0), "");
    }

    function test_wrongTokenVaultRevertsEvenIfSymbolIsOg() public {
        address otherOg = 0xf58a132967eF5eb52947031C86663Df5779ee2C6;
        OGClubFarmVault wrong = new OGClubFarmVault(IERC20(otherOg), owner);
        OGClubHookDeployer d =
            new OGClubHookDeployer(manager, address(og), address(wrong), 10000, owner, treasury, owner);
        (bytes32 salt, address expected) = HookSalt.find(address(d), d.initCodeHash(), 0, 1_000_000);
        vm.expectRevert(OGClubHook.WrongVaultToken.selector);
        d.deploy(salt, expected);
        assertEq(d.deployedHooks(salt), address(0));
        assertEq(expected.code.length, 0);
    }

    function test_zeroVaultShareDoesNotCallVaultToken() public {
        (OGClubHook h,) = _deploy(0, makeAddr("no vault code"), treasury);
        assertEq(h.VAULT_BPS(), 0);
    }

    function test_constructorRejectsBadBpsAndZeroOwner() public {
        vm.expectRevert(OGClubHookDeployer.InvalidConfiguration.selector);
        new OGClubHookDeployer(manager, address(og), address(vault), 10001, owner, treasury, owner);
        vm.expectRevert(OGClubHookDeployer.InvalidConfiguration.selector);
        new OGClubHookDeployer(manager, address(og), address(vault), 10000, address(0), treasury, owner);
        // Also exercise the hook's own check, independently of its deployer validation.
        bytes memory args = abi.encode(manager, address(og), address(vault), uint256(10001), owner, treasury, owner);
        bytes32 hash = keccak256(abi.encodePacked(type(OGClubHook).creationCode, args));
        (bytes32 salt,) = HookSalt.find(address(this), hash, 0, 1_000_000);
        vm.expectRevert(OGClubHook.InvalidVaultBps.selector);
        new OGClubHook{salt: salt}(manager, address(og), address(vault), 10001, owner, treasury, owner);
    }

    function test_badHookAddressRejectedByConstructor() public {
        bytes32 hash = keccak256(
            abi.encodePacked(
                type(OGClubHook).creationCode,
                abi.encode(manager, address(og), address(vault), uint256(10000), owner, treasury, owner)
            )
        );
        bytes32 salt;
        address expected = HookSalt.compute(address(this), salt, hash);
        assertTrue(uint160(expected) & 0x3fff != 0x20cc);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, expected));
        new OGClubHook{salt: salt}(manager, address(og), address(vault), 10000, owner, treasury, owner);
    }

    function test_deployerRejectsWrongPredictionFlagsAndRepeat() public {
        OGClubHookDeployer d =
            new OGClubHookDeployer(manager, address(og), address(vault), 10000, owner, treasury, owner);
        bytes32 salt;
        address expected = d.predict(salt);
        assertTrue(uint160(expected) & 0x3fff != 0x20cc);
        vm.expectRevert(OGClubHookDeployer.AddressMismatch.selector);
        d.deploy(salt, address(hook));
        vm.expectRevert(OGClubHookDeployer.InvalidFlags.selector);
        d.deploy(salt, expected);
        (salt, expected) = HookSalt.find(address(d), d.initCodeHash(), 0, 1_000_000);
        vm.prank(makeAddr("permissionless deploy caller"));
        OGClubHook h = d.deploy(salt, expected);
        assertEq(h.owner(), owner);
        assertFalse(h.opened());
        assertEq(address(d.deploy(salt, expected)), address(h), "same salt is idempotent");
        (bytes32 otherSalt, address otherExpected) =
            HookSalt.find(address(d), d.initCodeHash(), uint256(salt) + 1, 1_000_000);
        OGClubHook other = d.deploy(otherSalt, otherExpected);
        assertTrue(address(other) != address(h));
        assertEq(other.owner(), owner);
        assertEq(d.deployedHooks(salt), address(h));
    }

    function test_ownableTwoStepAndRenounceStillTradesAndFlushes() public {
        address next = makeAddr("next owner");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.transferOwnership(next);
        vm.prank(owner);
        hook.transferOwnership(next);
        assertEq(hook.owner(), owner);
        assertEq(hook.pendingOwner(), next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
        assertEq(hook.INITIALIZER(), owner);
        vm.prank(next);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));
        _swap(true, -1 ether);
        _ready();
        (, uint256 out,) = hook.flush();
        assertGt(out, 0);
        _conserved(hook);
    }

    function test_setTreasuryOnlyOwnerNonzeroAndDisabledAt100Percent() public {
        vm.prank(owner);
        vm.expectRevert(OGClubHook.TreasuryDisabled.selector);
        hook.setTreasury(makeAddr("next treasury"));
        (OGClubHook h,) = _deploy(5000, address(vault), treasury);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        h.setTreasury(owner);
        vm.prank(owner);
        vm.expectRevert(OGClubHook.InvalidAddress.selector);
        h.setTreasury(address(0));
        vm.prank(owner);
        h.setTreasury(owner);
        assertEq(h.treasury(), owner);
    }

    function test_noFeePauseSweepUpgradeOrGenericExecutionSelectors() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeWithSignature("setFee(uint256)", 1);
        calls[1] = abi.encodeWithSignature("setClubFeeBps(uint256)", 1);
        calls[2] = abi.encodeWithSignature("setVaultBps(uint256)", 1);
        calls[3] = abi.encodeWithSignature("pause()");
        calls[4] = abi.encodeWithSignature("unpause()");
        calls[5] = abi.encodeWithSignature("sweep(address,address,uint256)", address(og), owner, 1);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", owner);
        calls[7] = abi.encodeWithSignature("execute(address,bytes)", owner, bytes(""));
        calls[8] = abi.encodeWithSignature("setVault(address)", owner);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(hook).call(calls[i]);
            assertFalse(ok);
        }
    }

    function test_lpAddRemoveUntouched() public {
        PoolKey memory control = key;
        control.hooks = IHooks(address(0));
        manager.initialize(control, SQRT_ONE);
        BalanceDelta withHook = _liquidity(key, -200, 200, int256(100 ether));
        BalanceDelta withoutHook = _liquidity(control, -200, 200, int256(100 ether));
        assertEq(BalanceDelta.unwrap(withHook), BalanceDelta.unwrap(withoutHook));
        withHook = _liquidity(key, -200, 200, -int256(100 ether));
        withoutHook = _liquidity(control, -200, 200, -int256(100 ether));
        assertEq(BalanceDelta.unwrap(withHook), BalanceDelta.unwrap(withoutHook));
        assertEq(hook.pendingFees(), 0);
    }

    function test_runtimeSizeAndNoEscapeOpcodes() public view {
        _scan(address(hook));
        _scan(address(deployer));
    }

    function _scan(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
            if (op == 0 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }

    function test_flushBeforeOpenFails() public {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        vm.expectRevert(OGClubHook.NotOpened.selector);
        h.flush();
    }

    function test_noArbitraryNativeDeposits() public {
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_renounceBeforeOpeningRetainsInitializer() public {
        (OGClubHook h,) = _deploy(10000, address(vault), treasury);
        vm.prank(owner);
        h.renounceOwnership();
        _open(h, SQRT_ONE);
        assertTrue(h.opened());
        assertEq(h.owner(), address(0));
        assertEq(h.INITIALIZER(), owner);
    }
}
