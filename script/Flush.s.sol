// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OGClubHook} from "../src/OGClubHook.sol";

contract Flush is Script {
    function run(address hookAddress) external {
        OGClubHook hook = OGClubHook(payable(hookAddress));
        require(hook.opened(), "pool not open");
        require(block.timestamp >= hook.nextFlushAt(), "600 second interval not elapsed");
        console2.log("pending claims", hook.pendingFees());
        console2.log("deferred ETH", hook.heldEth());
        (uint256 buy, uint160 limit) = hook.previewBuy();
        console2.log("preview ETH buy", buy);
        console2.log("sqrt price limit", limit);
        vm.startBroadcast();
        (uint256 spent, uint256 out, uint256 paid) = hook.flush();
        vm.stopBroadcast();
        console2.log("ETH spent", spent);
        console2.log("OG sent to vault", out);
        console2.log("ETH sent to treasury", paid);
    }
}
