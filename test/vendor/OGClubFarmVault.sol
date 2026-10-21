// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Fee custody with delayed, budgeted Merkle seasons; there is no owner withdrawal or sweep.
contract OGClubFarmVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CLAIM_DELAY = 3 days;
    uint256 public constant PROPOSAL_INTERVAL = 7 days;
    uint256 public constant CLAIM_PERIOD = 90 days;
    IERC20 public immutable token;
    uint256 public reserved;
    uint256 public seasonCount;
    uint256 public lastProposedAt;

    struct Season {
        bytes32 root;
        uint256 remaining;
        uint256 opensAt;
        bool closed;
    }

    mapping(uint256 => Season) public seasons;
    mapping(uint256 => mapping(address => bool)) public claimed;

    error InvalidAddress();
    error InvalidSeason();
    error InvalidProposal();
    error ProposalTooSoon();
    error BudgetExceeded();
    error ClaimsNotOpen();
    error ClaimsClosed();
    error AlreadyClaimed();
    error InvalidProof();
    error CancellationTooLate();
    error ReleaseTooEarly();
    error UnexpectedTokenDebit();

    event SeasonProposed(uint256 indexed seasonId, bytes32 root, uint256 total, uint256 opensAt);
    event SeasonCancelled(uint256 indexed seasonId, uint256 released);
    event Claimed(uint256 indexed seasonId, address indexed account, uint256 amount);
    event SeasonReleased(uint256 indexed seasonId, uint256 released);

    constructor(IERC20 token_, address initialOwner) Ownable(initialOwner) {
        if (address(token_) == address(0)) revert InvalidAddress();
        token = token_;
    }

    function proposeSeason(bytes32 root, uint256 total) external onlyOwner nonReentrant returns (uint256 seasonId) {
        if (root == bytes32(0) || total == 0) revert InvalidProposal();
        if (seasonCount != 0 && block.timestamp < lastProposedAt + PROPOSAL_INTERVAL) revert ProposalTooSoon();
        if (total > (token.balanceOf(address(this)) - reserved) / 2) revert BudgetExceeded();
        seasonId = ++seasonCount;
        uint256 opensAt = block.timestamp + CLAIM_DELAY;
        seasons[seasonId] = Season(root, total, opensAt, false);
        lastProposedAt = block.timestamp;
        reserved += total;
        emit SeasonProposed(seasonId, root, total, opensAt);
    }

    function cancelSeason(uint256 seasonId) external onlyOwner nonReentrant {
        Season storage season = _season(seasonId);
        if (season.closed) revert ClaimsClosed();
        if (block.timestamp >= season.opensAt) revert CancellationTooLate();
        uint256 released = _close(season);
        emit SeasonCancelled(seasonId, released);
    }

    /// @notice Anyone can pay a valid allocation to its account. Leaf = keccak256(bytes.concat(keccak256(abi.encode(...)))).
    /// @dev Claims close exactly 90 days after opening, whether or not the owner releases the remainder.
    function claim(uint256 seasonId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Season storage season = _season(seasonId);
        if (block.timestamp < season.opensAt) revert ClaimsNotOpen();
        if (season.closed || block.timestamp >= season.opensAt + CLAIM_PERIOD) revert ClaimsClosed();
        if (account == address(0) || account == address(this)) revert InvalidAddress();
        if (claimed[seasonId][account]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(seasonId, account, amount))));
        if (!MerkleProof.verifyCalldata(proof, season.root, leaf)) revert InvalidProof();
        if (amount > season.remaining) revert BudgetExceeded();
        claimed[seasonId][account] = true;
        season.remaining -= amount;
        reserved -= amount;
        uint256 beforeBalance = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(account, amount);
        if (token.balanceOf(address(this)) != beforeBalance - amount) revert UnexpectedTokenDebit();
        emit Claimed(seasonId, account, amount);
    }

    function releaseSeason(uint256 seasonId) external onlyOwner nonReentrant {
        Season storage season = _season(seasonId);
        if (season.closed) revert ClaimsClosed();
        if (block.timestamp < season.opensAt + CLAIM_PERIOD) revert ReleaseTooEarly();
        uint256 released = _close(season);
        emit SeasonReleased(seasonId, released);
    }

    function _close(Season storage season) private returns (uint256 released) {
        released = season.remaining;
        reserved -= released;
        season.remaining = 0;
        season.closed = true;
    }

    function _season(uint256 seasonId) private view returns (Season storage season) {
        if (seasonId == 0 || seasonId > seasonCount) revert InvalidSeason();
        return seasons[seasonId];
    }
}
