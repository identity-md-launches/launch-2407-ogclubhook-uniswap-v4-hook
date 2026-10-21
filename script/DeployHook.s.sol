// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OGClubHook} from "../src/OGClubHook.sol";
import {OGClubHookDeployer} from "../src/OGClubHookDeployer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Networks} from "./Networks.sol";
import {HookSalt} from "./HookSalt.sol";

contract DeployHook is Script {
    /// @notice Optional direct deployment of the same application the IMD launch can deploy.
    /// No pool initialization or liquidity operation is included.
    function deployDeployer() external returns (OGClubHookDeployer d) {
        require(block.chainid == 1, "mainnet only");
        vm.startBroadcast();
        d = new OGClubHookDeployer(
            IPoolManager(Networks.MANAGER),
            Networks.OG,
            Networks.VAULT,
            10_000,
            Networks.OWNER,
            Networks.OWNER,
            Networks.OWNER
        );
        vm.stopBroadcast();
        console2.log("CREATE2 deployer; mine against this address", address(d));
    }

    function validate(OGClubHookDeployer d, bytes32 salt, address expected) public view {
        require(block.chainid == 1, "mainnet only");
        require(address(d).code.length != 0, "missing deployer");
        require(address(d.manager()) == Networks.MANAGER && d.og() == Networks.OG, "wrong manager/token");
        require(d.vault() == Networks.VAULT && d.vaultBps() == 10_000, "wrong vault/split");
        require(d.hookOwner() == Networks.OWNER, "wrong owner");
        require(d.treasury() == Networks.OWNER && d.initializer() == Networks.OWNER, "wrong treasury/initializer");
        require(d.deployedHooks(salt) == address(0), "salt already deployed");
        require(expected == d.predict(salt), "wrong CREATE2 address");
        require(uint160(expected) & 0x3fff == 0x20cc, "wrong hook permissions");
        require(expected.code.length == 0, "occupied hook address");
        bytes32 localHash = keccak256(
            abi.encodePacked(
                type(OGClubHook).creationCode,
                abi.encode(
                    Networks.MANAGER,
                    Networks.OG,
                    Networks.VAULT,
                    uint256(10000),
                    Networks.OWNER,
                    Networks.OWNER,
                    Networks.OWNER
                )
            )
        );
        require(d.initCodeHash() == localHash, "deployer build differs from this checkout");
        require(expected == HookSalt.compute(address(d), salt, localHash), "local CREATE2 prediction differs");
    }

    function run(address actualDeployer, bytes32 salt, address expected) external returns (OGClubHook hook) {
        OGClubHookDeployer d = OGClubHookDeployer(actualDeployer);
        validate(d, salt, expected); // All checks BEFORE starting a broadcast.
        vm.startBroadcast();
        hook = d.deploy(salt, expected);
        vm.stopBroadcast();
        require(address(hook) == expected && uint160(address(hook)) & 0x3fff == 0x20cc, "deployed flags");
        require(!hook.opened(), "pool unexpectedly opened");
        console2.log("mainnet hook", address(hook));
        console2.log("PoolId");
        console2.logBytes32(PoolId.unwrap(hook.POOL_ID()));
    }
}

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
