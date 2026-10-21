// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OGClubHookDeployer} from "../src/OGClubHookDeployer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DeployHook} from "../script/DeployHook.s.sol";
import {Networks} from "../script/Networks.sol";
import {HookSalt} from "../script/HookSalt.sol";
import {SepoliaRehearsal} from "../script/SepoliaRehearsal.s.sol";

contract DeploymentScriptsTest is Test {
    DeployHook private script;
    OGClubHookDeployer private deployer;
    bytes32 private salt;
    address private predicted;

    function setUp() public {
        vm.chainId(1);
        script = new DeployHook();
        deployer = new OGClubHookDeployer(
            IPoolManager(Networks.MANAGER),
            Networks.OG,
            Networks.VAULT,
            10000,
            Networks.OWNER,
            Networks.OWNER,
            Networks.OWNER
        );
        (salt, predicted) = HookSalt.find(address(deployer), deployer.initCodeHash(), 0, 1_000_000);
    }

    function test_correctConfigurationPassesPreBroadcastValidation() public view {
        script.validate(deployer, salt, predicted);
        assertEq(uint160(predicted) & 0x3fff, 0x20cc);
    }

    function test_wrongChainFailsBeforeBroadcast() public {
        vm.chainId(11155111);
        vm.expectRevert("mainnet only");
        script.validate(deployer, salt, predicted);
    }

    function test_wrongDeployerOrSaltFailsBeforeBroadcast() public {
        OGClubHookDeployer other = new OGClubHookDeployer(
            IPoolManager(Networks.MANAGER),
            Networks.OG,
            Networks.VAULT,
            10000,
            Networks.OWNER,
            Networks.OWNER,
            Networks.OWNER
        );
        vm.expectRevert("wrong CREATE2 address");
        script.validate(other, salt, predicted);
        vm.expectRevert("wrong CREATE2 address");
        script.validate(deployer, bytes32(uint256(salt) + 1), predicted);
    }

    function test_wrongOwnerFailsBeforeBroadcast() public {
        OGClubHookDeployer other = new OGClubHookDeployer(
            IPoolManager(Networks.MANAGER),
            Networks.OG,
            Networks.VAULT,
            10000,
            makeAddr("wrong owner"),
            Networks.OWNER,
            Networks.OWNER
        );
        vm.expectRevert("wrong owner");
        script.validate(other, salt, predicted);
    }

    function test_emptySearchFailsClosed() public {
        vm.expectRevert(HookSalt.SaltNotFound.selector);
        this.search(0);
    }

    function test_sepoliaDefaultCannotRunInheritedMainnetOpening() public {
        SepoliaRehearsal rehearsal = new SepoliaRehearsal();
        vm.expectRevert("select a named Sepolia rehearsal phase");
        rehearsal.run();
        vm.expectRevert("Sepolia only");
        rehearsal.deployDeployer(Networks.OWNER);
    }

    function search(uint256 attempts) external view {
        HookSalt.find(address(deployer), deployer.initCodeHash(), 0, attempts);
    }
}
