// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {OGClubHook} from "../src/OGClubHook.sol";
import {OGClubHookDeployer} from "../src/OGClubHookDeployer.sol";
import {OGClubFarmVault} from "./vendor/OGClubFarmVault.sol";
import {HookSalt} from "../script/HookSalt.sol";
import {Networks} from "../script/Networks.sol";
import {OpenPool} from "../script/OpenPool.s.sol";
import {SwapPlan, IUniversalRouterExecute} from "../script/SwapPlan.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

abstract contract ForkRehearsal is Test {
    function network()
        internal
        pure
        virtual
        returns (
            uint256 chain,
            uint256 pinned,
            address manager,
            address og,
            address vault,
            address positionManager,
            address universalRouter
        );

    function test_pinnedLiveContractsOpenSwapFlushAndSeasonClaim() public {
        (
            uint256 chain,
            uint256 pinned,
            address manager,
            address token,
            address vaultAddress,
            address positions,
            address universalRouter
        ) = network();
        // Opt in only with forge test --fork-url ... --fork-block-number ... . No env in tests.
        if (block.chainid != chain) {
            vm.skip(true);
            return;
        }
        assertEq(block.number, pinned, "use the documented pinned block");
        require(
            manager.code.length != 0 && positions.code.length != 0 && universalRouter.code.length != 0,
            "missing protocol code"
        );
        OGClubFarmVault vault = OGClubFarmVault(vaultAddress);
        assertEq(address(vault.token()), token);

        address initializer = Networks.OWNER;
        OGClubHookDeployer d = new OGClubHookDeployer(
            IPoolManager(manager), token, vaultAddress, 10000, initializer, initializer, initializer
        );
        (bytes32 salt, address predicted) = HookSalt.find(address(d), d.initCodeHash(), 0, 1_000_000);
        OGClubHook h = d.deploy(salt, predicted);
        assertEq(uint160(address(h)) & 0x3fff, 0x20cc);
        uint160 price;
        if (chain == 1) (price,,,) = IStateView(Networks.STATE_VIEW).getSlot0(PoolId.wrap(Networks.OLD_POOL_ID));
        else price = 1 << 96; // Explicit 1:1 test price; never used for mainnet opening.
        uint128 ogMax = chain == 1 ? uint128(200_000_000 ether) : uint128(2 ether);
        vm.deal(initializer, 100 ether);
        deal(token, initializer, uint256(ogMax) * 2); // Fork-only funding, not a live-chain transaction.
        OpenPool builder = new OpenPool();
        (bytes[] memory calls,) = builder.build(
            OpenPool.OpenConfig(
                h, price, price, price, 2 ether, ogMax, vm.getBlockTimestamp() + 900, OpenPool.Preset.A, initializer
            )
        );
        vm.startPrank(initializer, initializer);
        IERC20(token).approve(Networks.PERMIT2, ogMax);
        IAllowanceTransfer(Networks.PERMIT2).approve(token, positions, ogMax, uint48(vm.getBlockTimestamp() + 900));
        IPositionManager(positions).multicall{value: 2 ether}(calls);
        vm.stopPrank();
        assertTrue(h.opened());

        uint256 ogBefore = IERC20(token).balanceOf(initializer);
        (bytes memory commands, bytes[] memory inputs) = SwapPlan.exactInput(h, true, 0.02 ether, 1);
        vm.prank(initializer, initializer);
        IUniversalRouterExecute(universalRouter).execute{value: 0.02 ether}(
            commands, inputs, vm.getBlockTimestamp() + 900
        );
        uint256 bought = IERC20(token).balanceOf(initializer) - ogBefore;
        assertGt(bought, 0);
        uint128 sellAmount = uint128(bought / 2);
        (commands, inputs) = SwapPlan.exactInput(h, false, sellAmount, 1);
        vm.startPrank(initializer, initializer);
        IERC20(token).approve(Networks.PERMIT2, sellAmount);
        IAllowanceTransfer(Networks.PERMIT2)
            .approve(token, universalRouter, sellAmount, uint48(vm.getBlockTimestamp() + 900));
        IUniversalRouterExecute(universalRouter).execute(commands, inputs, vm.getBlockTimestamp() + 900);
        vm.stopPrank();

        uint256 vaultBefore = IERC20(token).balanceOf(vaultAddress);
        vm.warp(h.nextFlushAt());
        (uint256 spent, uint256 out,) = h.flush();
        uint256 vaultAfter = IERC20(token).balanceOf(vaultAddress);
        assertGt(spent, 0);
        assertEq(vaultAfter - vaultBefore, out);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(address(h)), 0);
        assertEq(h.pendingFees() + h.totalSpent(), h.totalFees());
        console2.log("chain", chain);
        console2.log("pinned block", pinned);
        console2.log("fork-only hook", address(h));
        console2.log("vault OG before", vaultBefore);
        console2.log("vault OG after", vaultAfter);
        console2.log("ETH spent", spent);
        console2.log("OG funded", out);

        uint256 award = out / 2;
        uint256 seasonId = vault.seasonCount() + 1;
        address farmer = makeAddr("fork farmer");
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(seasonId, farmer, award))));
        if (vault.seasonCount() != 0 && vm.getBlockTimestamp() < vault.lastProposedAt() + vault.PROPOSAL_INTERVAL()) {
            vm.warp(vault.lastProposedAt() + vault.PROPOSAL_INTERVAL());
        }
        address vaultOwner = vault.owner();
        require(vaultOwner != address(0), "live vault has renounced proposal authority");
        vm.prank(vaultOwner);
        assertEq(vault.proposeSeason(root, award), seasonId);
        vm.warp(vm.getBlockTimestamp() + vault.CLAIM_DELAY());
        vault.claim(seasonId, farmer, award, new bytes32[](0));
        assertEq(IERC20(token).balanceOf(farmer), award);
    }
}

contract MainnetForkTest is ForkRehearsal {
    function network() internal pure override returns (uint256, uint256, address, address, address, address, address) {
        return (
            1,
            26242828,
            Networks.MANAGER,
            Networks.OG,
            Networks.VAULT,
            Networks.POSITION_MANAGER,
            Networks.UNIVERSAL_ROUTER
        );
    }
}

contract SepoliaForkTest is ForkRehearsal {
    function network() internal pure override returns (uint256, uint256, address, address, address, address, address) {
        return (
            11155111,
            11964302,
            Networks.SEPOLIA_MANAGER,
            Networks.SEPOLIA_OG,
            Networks.SEPOLIA_VAULT,
            Networks.SEPOLIA_POSITION_MANAGER,
            Networks.SEPOLIA_UNIVERSAL_ROUTER
        );
    }
}
