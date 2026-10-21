// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @notice Salt search with the ACTUAL CREATE2 deployer and constructor-inclusive init-code hash.
library HookSalt {
    error SaltNotFound();

    function compute(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        // Reuses scratch memory so a long off-chain search does not grow memory every iteration.
        return Create2.computeAddress(salt, initCodeHash, deployer);
    }

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = compute(deployer, salt, initCodeHash);
            if (uint160(predicted) & 0x3fff == 0x20cc && predicted.code.length == 0) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
