// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture, OGClubFarmVault} from "./helpers/HookFixture.sol";

/// @notice Uses the unmodified farm vault at the requested c77c192 source revision.
contract RealVaultTest is HookFixture {
    function test_swapsFlushSeasonProposalAndClaim() public {
        _swap(true, -10 ether);
        _swap(false, -1 ether);
        _ready();
        uint256 beforeBalance = og.balanceOf(address(vault));
        (, uint256 out,) = hook.flush();
        assertEq(og.balanceOf(address(vault)) - beforeBalance, out);
        uint256 award = out / 2;
        address farmer = makeAddr("farmer");
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(uint256(1), farmer, award))));
        vm.prank(owner);
        uint256 season = vault.proposeSeason(root, award);
        assertEq(season, 1);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(OGClubFarmVault.ClaimsNotOpen.selector);
        vault.claim(season, farmer, award, proof);
        vm.warp(block.timestamp + vault.CLAIM_DELAY());
        vault.claim(season, farmer, award, proof);
        assertEq(og.balanceOf(farmer), award);
        assertEq(vault.reserved(), 0);
        vm.expectRevert(OGClubFarmVault.AlreadyClaimed.selector);
        vault.claim(season, farmer, award, proof);
        _conserved(hook);
    }
}
