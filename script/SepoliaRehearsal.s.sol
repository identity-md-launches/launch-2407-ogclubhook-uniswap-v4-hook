// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OGClubHook} from "../src/OGClubHook.sol";
import {OGClubHookDeployer} from "../src/OGClubHookDeployer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OpenPool} from "./OpenPool.s.sol";
import {Networks} from "./Networks.sol";
import {SwapPlan, IUniversalRouterExecute} from "./SwapPlan.sol";
import {HookSalt} from "./HookSalt.sol";

/// @notice Separate transactions/phases; no sleeping or fake on-chain timestamp advancement.
contract SepoliaRehearsal is OpenPool {
    /// @dev Never inherit OpenPool's default mainnet entry point into this rehearsal script.
    function run() external pure override {
        revert("select a named Sepolia rehearsal phase");
    }

    function _sepolia() private view {
        require(block.chainid == 11155111, "Sepolia only");
    }

    function _check(OGClubHook h) private view {
        _sepolia();
        require(address(h.poolManager()) == Networks.SEPOLIA_MANAGER && h.OG() == Networks.SEPOLIA_OG, "pool mismatch");
        require(h.VAULT() == Networks.SEPOLIA_VAULT && h.VAULT_BPS() == 10000, "vault mismatch");
        require(uint160(address(h)) & 0x3fff == 0x20cc, "flags");
    }

    function deployDeployer(address rehearsalOwner) external returns (OGClubHookDeployer d) {
        _sepolia();
        require(rehearsalOwner != address(0), "owner required");
        vm.startBroadcast();
        d = new OGClubHookDeployer(
            IPoolManager(Networks.SEPOLIA_MANAGER),
            Networks.SEPOLIA_OG,
            Networks.SEPOLIA_VAULT,
            10000,
            rehearsalOwner,
            rehearsalOwner,
            rehearsalOwner
        );
        vm.stopBroadcast();
        console2.log("Sepolia CREATE2 deployer", address(d));
    }

    function deployHook(address actualDeployer, bytes32 salt, address expected) external returns (OGClubHook h) {
        _sepolia();
        OGClubHookDeployer d = OGClubHookDeployer(actualDeployer);
        require(address(d.manager()) == Networks.SEPOLIA_MANAGER && d.og() == Networks.SEPOLIA_OG, "pool mismatch");
        require(d.vault() == Networks.SEPOLIA_VAULT && d.vaultBps() == 10000, "vault mismatch");
        require(d.hookOwner() == d.initializer() && d.hookOwner() == d.treasury(), "roles mismatch");
        require(d.predict(salt) == expected && uint160(expected) & 0x3fff == 0x20cc, "address/flags");
        require(d.deployedHooks(salt) == address(0) && expected.code.length == 0, "already deployed");
        bytes32 localHash = keccak256(
            abi.encodePacked(
                type(OGClubHook).creationCode,
                abi.encode(
                    Networks.SEPOLIA_MANAGER,
                    Networks.SEPOLIA_OG,
                    Networks.SEPOLIA_VAULT,
                    uint256(10000),
                    d.hookOwner(),
                    d.treasury(),
                    d.initializer()
                )
            )
        );
        require(localHash == d.initCodeHash(), "deployer build differs");
        require(expected == HookSalt.compute(address(d), salt, localHash), "local prediction differs");
        vm.startBroadcast();
        h = d.deploy(salt, expected);
        vm.stopBroadcast();
        _check(h);
        console2.log("Sepolia hook", address(h));
    }

    function open(address hookAddress, uint160 price, uint128 ethMax, uint128 ogMax) external {
        OGClubHook h = OGClubHook(payable(hookAddress));
        _check(h);
        require(!h.opened(), "already open");
        uint256 deadline = block.timestamp + 900;
        address initializer = h.INITIALIZER();
        (bytes[] memory calls,) =
            build(OpenConfig(h, price, price, price, ethMax, ogMax, deadline, Preset.A, initializer));
        vm.startBroadcast(initializer);
        require(IERC20(Networks.SEPOLIA_OG).approve(Networks.PERMIT2, ogMax), "approval");
        IAllowanceTransfer(Networks.PERMIT2)
            .approve(Networks.SEPOLIA_OG, Networks.SEPOLIA_POSITION_MANAGER, ogMax, uint48(deadline));
        IPositionManager(Networks.SEPOLIA_POSITION_MANAGER).multicall{value: ethMax}(calls);
        vm.stopBroadcast();
        require(h.opened(), "not opened");
        console2.log("next flush timestamp", h.nextFlushAt());
    }

    function swap(address hookAddress, bool ethToOg, uint128 amount, uint128 minOut) external {
        OGClubHook h = OGClubHook(payable(hookAddress));
        _check(h);
        require(h.opened(), "not open");
        (bytes memory commands, bytes[] memory inputs) = SwapPlan.exactInput(h, ethToOg, amount, minOut);
        uint256 deadline = block.timestamp + 900;
        vm.startBroadcast();
        if (!ethToOg) {
            require(IERC20(Networks.SEPOLIA_OG).approve(Networks.PERMIT2, amount), "approval");
            IAllowanceTransfer(Networks.PERMIT2)
                .approve(Networks.SEPOLIA_OG, Networks.SEPOLIA_UNIVERSAL_ROUTER, amount, uint48(deadline));
        }
        IUniversalRouterExecute(Networks.SEPOLIA_UNIVERSAL_ROUTER).execute{value: ethToOg ? amount : 0}(
            commands, inputs, deadline
        );
        vm.stopBroadcast();
        console2.log("pending fees", h.pendingFees());
    }

    function finish(address hookAddress) external {
        OGClubHook h = OGClubHook(payable(hookAddress));
        _check(h);
        require(block.timestamp >= h.nextFlushAt(), "run at nextFlushAt; this script never sleeps");
        uint256 beforeBalance = IERC20(Networks.SEPOLIA_OG).balanceOf(Networks.SEPOLIA_VAULT);
        vm.startBroadcast();
        (uint256 spent, uint256 out,) = h.flush();
        vm.stopBroadcast();
        uint256 afterBalance = IERC20(Networks.SEPOLIA_OG).balanceOf(Networks.SEPOLIA_VAULT);
        require(out != 0 && afterBalance - beforeBalance == out, "vault funding not demonstrated");
        require(IERC20(Networks.SEPOLIA_OG).balanceOf(address(h)) == 0, "hook retained OG");
        console2.log("vault OG before", beforeBalance);
        console2.log("vault OG after", afterBalance);
        console2.log("ETH spent", spent);
        console2.log("OG funded", out);
    }
}
