// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OGClubHook} from "./OGClubHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice A launch-factory-compatible application that CREATE2-deploys hooks with fixed parameters.
/// @dev Constructor makes no external calls. The hook performs its required vault-token check at deploy().
/// Anybody may deploy the fixed configuration; nobody may replace its owner or beneficiaries.
contract OGClubHookDeployer {
    IPoolManager public immutable manager;
    address public immutable og;
    address public immutable vault;
    uint256 public immutable vaultBps;
    address public immutable hookOwner;
    address public immutable treasury;
    address public immutable initializer;
    mapping(bytes32 salt => address hook) public deployedHooks;

    error InvalidConfiguration();
    error AddressMismatch();
    error InvalidFlags();

    event HookDeployed(address indexed hook, bytes32 indexed salt, bytes32 initCodeHash);

    constructor(
        IPoolManager manager_,
        address og_,
        address vault_,
        uint256 vaultBps_,
        address owner_,
        address treasury_,
        address initializer_
    ) {
        if (
            address(manager_) == address(0) || og_ == address(0) || vault_ == address(0) || owner_ == address(0)
                || treasury_ == address(0) || initializer_ == address(0) || vaultBps_ > 10_000
        ) revert InvalidConfiguration();
        manager = manager_;
        og = og_;
        vault = vault_;
        vaultBps = vaultBps_;
        hookOwner = owner_;
        treasury = treasury_;
        initializer = initializer_;
    }

    function initCodeHash() public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(OGClubHook).creationCode,
                abi.encode(manager, og, vault, vaultBps, hookOwner, treasury, initializer)
            )
        );
    }

    function predict(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash())))));
    }

    function deploy(bytes32 salt, address expected) external returns (OGClubHook hook) {
        if (expected != predict(salt)) revert AddressMismatch();
        if (uint160(expected) & 0x3fff != 0x20cc) revert InvalidFlags();
        // Idempotent for this salt; a permissionless caller cannot reserve a different
        // salt to block the intended deployment. All hooks have the same fixed roles.
        if (deployedHooks[salt] != address(0)) return OGClubHook(payable(deployedHooks[salt]));
        hook = new OGClubHook{salt: salt}(manager, og, vault, vaultBps, hookOwner, treasury, initializer);
        if (address(hook) != expected) revert AddressMismatch();
        deployedHooks[salt] = address(hook);
        emit HookDeployed(address(hook), salt, initCodeHash());
    }
}
