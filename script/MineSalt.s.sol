// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OGClubHookDeployer} from "../src/OGClubHookDeployer.sol";
import {HookSalt} from "./HookSalt.sol";

contract MineSalt is Script {
    function run(address actualDeployer, uint256 start, uint256 attempts)
        external
        view
        returns (bytes32 salt, address hook)
    {
        require(actualDeployer.code.length != 0, "deployer has no code on this chain");
        bytes32 hash = OGClubHookDeployer(actualDeployer).initCodeHash();
        (salt, hook) = HookSalt.find(actualDeployer, hash, start, attempts);
        console2.log("chain", block.chainid);
        console2.log("actual CREATE2 deployer", actualDeployer);
        console2.log("initCodeHash");
        console2.logBytes32(hash);
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("predicted hook", hook);
        require(uint160(hook) & 0x3fff == 0x20cc, "flags");
    }
}
