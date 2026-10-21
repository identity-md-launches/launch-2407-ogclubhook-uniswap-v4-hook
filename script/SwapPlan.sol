// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OGClubHook} from "../src/OGClubHook.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IUniversalRouterExecute {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

library SwapPlan {
    function exactInput(OGClubHook hook, bool ethToOg, uint128 amount, uint128 minOut)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        require(amount != 0 && minOut != 0, "amount and minOut required");
        PoolKey memory key = hook.poolKey();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, ethToOg, amount, minOut, ""));
        params[1] = abi.encode(ethToOg ? key.currency0 : key.currency1, uint256(amount));
        params[2] = abi.encode(ethToOg ? key.currency1 : key.currency0, uint256(minOut));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)),
            params
        );
        commands = hex"10"; // Universal Router Commands.V4_SWAP; do not allow failure.
    }
}
