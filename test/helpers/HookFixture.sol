// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {OGClubHook} from "../../src/OGClubHook.sol";
import {OGClubHookDeployer} from "../../src/OGClubHookDeployer.sol";
import {OGClubFarmVault} from "../vendor/OGClubFarmVault.sol";
import {HookSalt} from "../../script/HookSalt.sol";

contract TestOG is ERC20 {
    constructor() ERC20("Test OG", "OG") {}

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal manager;
    TestOG internal og;
    OGClubFarmVault internal vault;
    OGClubHook internal hook;
    OGClubHookDeployer internal deployer;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal lp;
    PoolKey internal key;
    address internal owner;
    address internal treasury;
    uint256 internal constant INITIAL_LIQUIDITY = 1_000 ether;
    uint160 internal constant SQRT_ONE = 1 << 96;

    function setUp() public virtual {
        vm.warp(1_000_000);
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        manager = IPoolManager(address(new PoolManager(owner)));
        og = new TestOG();
        vault = new OGClubFarmVault(IERC20(address(og)), owner);
        router = new PoolSwapTest(manager);
        lp = new PoolModifyLiquidityTest(manager);
        vm.deal(address(this), 1_000_000 ether);
        og.mint(address(this), 1_000_000_000 ether);
        og.approve(address(router), type(uint256).max);
        og.approve(address(lp), type(uint256).max);
        (hook, deployer) = _deploy(10_000, address(vault), treasury);
        key = hook.poolKey();
        _open(hook, SQRT_ONE);
        _liquidity(key, -887200, 887200, int256(INITIAL_LIQUIDITY));
    }

    function _deploy(uint256 bps, address vault_, address treasury_)
        internal
        returns (OGClubHook h, OGClubHookDeployer d)
    {
        d = new OGClubHookDeployer(manager, address(og), vault_, bps, owner, treasury_, owner);
        (bytes32 salt, address predicted) = HookSalt.find(address(d), d.initCodeHash(), 0, 1_000_000);
        h = d.deploy(salt, predicted);
        assertEq(address(h), predicted);
    }

    function _open(OGClubHook h, uint160 price) internal {
        PoolKey memory k = h.poolKey();
        vm.prank(owner, owner);
        manager.initialize(k, price);
    }

    function _liquidity(PoolKey memory k, int24 lower, int24 upper, int256 amount) internal returns (BalanceDelta) {
        return lp.modifyLiquidity{value: 10_000 ether}(k, ModifyLiquidityParams(lower, upper, amount, 0), "");
    }

    function _swap(bool zeroForOne, int256 amount) internal returns (BalanceDelta) {
        return _swapKey(key, zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function _swapKey(PoolKey memory k, bool zeroForOne, int256 amount, uint160 limit) internal returns (BalanceDelta) {
        return router.swap{value: 10_000 ether}(
            k, SwapParams(zeroForOne, amount, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _ready() internal {
        vm.warp(hook.nextFlushAt());
    }

    function _conserved(OGClubHook h) internal view {
        assertEq(h.pendingFees() + h.heldEth() + h.totalSpent() + h.totalFlushed(), h.totalFees(), "ETH conservation");
        assertEq(og.balanceOf(address(h)), 0, "hook must not take OG");
        assertEq(address(h).balance, h.heldEth(), "only deferred ETH is held");
        assertEq(manager.currencyDelta(address(h), Currency.wrap(address(0))), 0, "unsettled ETH");
        assertEq(manager.currencyDelta(address(h), Currency.wrap(address(og))), 0, "unsettled OG");
    }

    receive() external payable {}
}
