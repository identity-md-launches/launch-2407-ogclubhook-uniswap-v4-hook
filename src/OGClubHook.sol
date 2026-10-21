// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IOGClubVault {
    function token() external view returns (address);
}

/// @notice One immutable ETH/OG pool, with ETH-only fees held as PoolManager claims.
/// @dev Normal operation never takes OG into this contract. Unsolicited token transfers cannot be prevented.
contract OGClubHook is BaseHook, Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint256 public constant CLUB_FEE_BPS = 100;
    uint256 public constant RESERVE_CAP_BPS = 50;
    uint256 public constant MAX_FLUSH_ETH = 0.5 ether;
    uint256 public constant MAX_IMPACT_BPS = 200;
    uint256 public constant MIN_FLUSH_INTERVAL = 600;
    uint256 public constant MIN_BUY_ETH = 0.0001 ether;
    uint24 public constant LP_FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    uint160 public constant HOOK_FLAGS = 0x20cc;

    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 1 << 96;
    // ceil(sqrt(10000 / (10000 + MAX_IMPACT_BPS)) * 1e18).
    // ETH/OG rises at most 2%; the reciprocal OG/ETH falls at most 1.960785%.
    // Thus the price move stays within 2% in either denomination (not 2% in sqrt-price).
    uint256 private constant MIN_SQRT_PRICE_FACTOR = 990147542976674310;
    uint256 private constant TREASURY_GAS_LIMIT = 50_000;

    address public immutable OG;
    address public immutable VAULT;
    uint256 public immutable VAULT_BPS;
    address public immutable INITIALIZER;
    PoolId public immutable POOL_ID;

    address public treasury;
    bool public opened;
    uint256 public lastFlush;
    uint256 public heldEth;
    uint256 public totalFees;
    uint256 public totalSpent;
    uint256 public totalFlushed;
    bool private awaitingUnlock;

    error InvalidAddress();
    error InvalidVaultBps();
    error WrongVaultToken();
    error WrongPool();
    error AlreadyOpened();
    error NotOpened();
    error NotInitializer();
    error InvalidAmount();
    error EthPartialFill();
    error MidUnlock();
    error FlushTooSoon(uint256 nextAt);
    error UnexpectedCallback();
    error TreasuryDisabled();
    error UnexpectedSwapDelta();

    event PoolOpened(PoolId indexed poolId, uint160 sqrtPriceX96);
    event ClubFee(address indexed sender, bool zeroForOne, bool exactInput, uint256 ethFee);
    event VaultFunded(address indexed caller, uint256 ethSpent, uint256 ogToVault);
    event Flushed(address indexed caller, uint256 ethSpent, uint256 ethToTreasury, uint256 remainingClaims);
    event FlushDeferred(address indexed treasury, uint256 heldEth);
    event TreasuryChanged(address indexed previousTreasury, address indexed newTreasury);

    constructor(
        IPoolManager manager,
        address og,
        address vault,
        uint256 vaultBps,
        address owner_,
        address treasury_,
        address initializer
    ) BaseHook(manager) Ownable(owner_) {
        if (
            address(manager) == address(0) || og == address(0) || vault == address(0) || treasury_ == address(0)
                || initializer == address(0)
        ) revert InvalidAddress();
        if (vaultBps > BPS) revert InvalidVaultBps();
        if (vaultBps != 0 && IOGClubVault(vault).token() != og) revert WrongVaultToken();
        OG = og;
        VAULT = vault;
        VAULT_BPS = vaultBps;
        INITIALIZER = initializer;
        treasury = treasury_;
        POOL_ID =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(og), LP_FEE, TICK_SPACING, IHooks(address(this))).toId();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(OG), LP_FEE, TICK_SPACING, IHooks(address(this)));
    }

    function setTreasury(address next) external onlyOwner {
        if (VAULT_BPS == BPS) revert TreasuryDisabled();
        if (next == address(0)) revert InvalidAddress();
        emit TreasuryChanged(treasury, next);
        treasury = next;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(POOL_ID)) revert WrongPool();
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        _checkPool(key);
        if (opened) revert AlreadyOpened();
        // The sole use of tx.origin: permits the initializer's PositionManager multicall.
        if (tx.origin != INITIALIZER) revert NotInitializer();
        opened = true;
        lastFlush = block.timestamp;
        emit PoolOpened(POOL_ID, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (!opened) revert NotOpened();
        int256 specified = params.amountSpecified;
        // Pool deltas are int128; bound before negation, multiplication or downcasts.
        if (specified == 0 || specified < -int256(type(int128).max) || specified > int256(type(int128).max)) {
            revert InvalidAmount();
        }
        uint256 fee;
        if (params.zeroForOne && specified < 0) {
            fee = uint256(-specified) * CLUB_FEE_BPS / BPS;
        } else if (!params.zeroForOne && specified > 0) {
            uint256 gross = FullMath.mulDivRoundingUp(uint256(specified), BPS, BPS - CLUB_FEE_BPS);
            if (gross > uint256(uint128(type(int128).max))) revert InvalidAmount();
            fee = gross - uint256(specified);
        } else {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        _accrue(sender, params, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _checkPool(key);
        int256 ethDelta = int256(delta.amount0());
        int256 specified = params.amountSpecified;
        if (params.zeroForOne && specified < 0) {
            uint256 specifiedFee = uint256(-specified) * CLUB_FEE_BPS / BPS;
            if (ethDelta != specified + int256(specifiedFee)) revert EthPartialFill();
            return (IHooks.afterSwap.selector, 0);
        }
        if (!params.zeroForOne && specified > 0) {
            uint256 gross = FullMath.mulDivRoundingUp(uint256(specified), BPS, BPS - CLUB_FEE_BPS);
            if (ethDelta != int256(gross)) revert EthPartialFill();
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 fee;
        if (params.zeroForOne) {
            if (ethDelta > 0) revert UnexpectedSwapDelta();
            fee = uint256(-ethDelta) * CLUB_FEE_BPS / (BPS - CLUB_FEE_BPS);
        } else {
            if (ethDelta < 0) revert UnexpectedSwapDelta();
            fee = uint256(ethDelta) * CLUB_FEE_BPS / BPS;
        }
        _accrue(sender, params, fee);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function _accrue(address sender, SwapParams calldata params, uint256 fee) private {
        if (fee != 0) {
            poolManager.mint(address(this), 0, fee);
            totalFees += fee;
        }
        emit ClubFee(sender, params.zeroForOne, params.amountSpecified < 0, fee);
    }

    /// @notice Outstanding native-currency ERC-6909 claims; excludes deferred treasury ETH.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), 0);
    }

    function nextFlushAt() public view returns (uint256) {
        return lastFlush + MIN_FLUSH_INTERVAL;
    }

    /// @notice A spot-state estimate, not a guaranteed quote or an external price oracle.
    function previewBuy() public view returns (uint256 ethToBuy, uint160 sqrtPriceLimitX96) {
        if (!opened) return (0, 0);
        return _preview(FullMath.mulDiv(pendingFees(), VAULT_BPS, BPS));
    }

    function _preview(uint256 vaultPart) private view returns (uint256 buy, uint160 limit) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(POOL_ID);
        uint128 liquidity = poolManager.getLiquidity(POOL_ID);
        if (liquidity == 0 || sqrtPriceX96 == 0) return (0, 0);
        uint256 virtualEth = FullMath.mulDiv(liquidity, Q96, sqrtPriceX96);
        uint256 reserveCap = FullMath.mulDiv(virtualEth, RESERVE_CAP_BPS, BPS);
        buy = vaultPart < reserveCap ? vaultPart : reserveCap;
        if (buy > MAX_FLUSH_ETH) buy = MAX_FLUSH_ETH;
        if (buy < MIN_BUY_ETH) return (0, 0);
        limit = uint160(FullMath.mulDivRoundingUp(sqrtPriceX96, MIN_SQRT_PRICE_FACTOR, 1e18));
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= sqrtPriceX96) return (0, 0);
    }

    /// @notice Anyone can fund the vault and retry deferred treasury ETH every 600 seconds.
    function flush() external nonReentrant returns (uint256 ethSpent, uint256 ogToVault, uint256 ethToTreasury) {
        if (poolManager.isUnlocked()) revert MidUnlock();
        if (!opened) revert NotOpened();
        if (block.timestamp < nextFlushAt()) revert FlushTooSoon(nextFlushAt());
        lastFlush = block.timestamp;
        awaitingUnlock = true;
        return abi.decode(poolManager.unlock(abi.encode(msg.sender)), (uint256, uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!awaitingUnlock || !_reentrancyGuardEntered()) revert UnexpectedCallback();
        awaitingUnlock = false;
        address caller = abi.decode(data, (address));
        uint256 claims = pendingFees();
        uint256 vaultPart = FullMath.mulDiv(claims, VAULT_BPS, BPS);
        uint256 clubPart = claims - vaultPart;
        (uint256 buy, uint160 limit) = _preview(vaultPart);
        uint256 spent = 0;
        uint256 ogOut = 0;
        if (buy != 0) {
            // v4's noSelfCall rule suppresses BOTH swap hooks for this exact caller.
            BalanceDelta delta = poolManager.swap(poolKey(), SwapParams(true, -int256(buy), limit), "");
            if (delta.amount0() > 0 || delta.amount1() < 0) revert UnexpectedSwapDelta();
            spent = uint256(-int256(delta.amount0()));
            ogOut = uint256(int256(delta.amount1()));
            if (spent > buy) revert UnexpectedSwapDelta();
        }
        uint256 burn = spent + clubPart;
        if (burn != 0) poolManager.burn(address(this), 0, burn);
        totalSpent += spent;
        if (ogOut != 0) poolManager.take(Currency.wrap(OG), VAULT, ogOut);
        if (spent != 0 || ogOut != 0) emit VaultFunded(caller, spent, ogOut);
        if (clubPart != 0) {
            heldEth += clubPart;
            poolManager.take(Currency.wrap(address(0)), address(this), clubPart);
        }

        uint256 paid = heldEth;
        if (paid != 0) {
            heldEth = 0;
            // Bound recipient gas so rejection (including consuming its gas) cannot veto vault funding.
            (bool ok,) = treasury.call{value: paid, gas: TREASURY_GAS_LIMIT}("");
            if (ok) {
                totalFlushed += paid;
            } else {
                heldEth = paid;
                emit FlushDeferred(treasury, paid);
                paid = 0;
            }
        }
        emit Flushed(caller, spent, paid, pendingFees());
        return abi.encode(spent, ogOut, paid);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedCallback();
    }
}
