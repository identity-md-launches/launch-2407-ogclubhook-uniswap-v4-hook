// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {OGClubHook} from "../src/OGClubHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "@uniswap/v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Networks} from "./Networks.sol";

/// @notice Owner-run only. The only pool opening entry point in the mainnet scripts.
contract OpenPool is Script {
    enum Preset {
        A,
        B,
        C
    }

    struct OpenConfig {
        OGClubHook hook;
        uint160 sqrtPriceX96;
        uint160 minSqrtPriceX96; // owner's acceptance band for the live old-pool read, inclusive
        uint160 maxSqrtPriceX96;
        uint128 ethMax;
        uint128 ogMax;
        uint256 deadline;
        Preset preset;
        address recipient;
    }

    function ticks(Preset preset) public pure returns (int24 lower, int24 upper) {
        if (preset == Preset.A) return (-887200, 887200);
        if (preset == Preset.B) return (172600, 186600);
        return (165600, 179400);
    }

    /// @notice Pure transaction construction apart from reading the immutable hook PoolKey.
    /// Testable without broadcast, env, signer identity or external RPCs.
    function build(OpenConfig memory c) public view returns (bytes[] memory calls, uint128 liquidity) {
        require(c.recipient != address(0), "recipient");
        require(c.sqrtPriceX96 > TickMath.MIN_SQRT_PRICE && c.sqrtPriceX96 < TickMath.MAX_SQRT_PRICE, "price");
        require(c.minSqrtPriceX96 != 0 && c.minSqrtPriceX96 <= c.maxSqrtPriceX96, "price band");
        require(
            c.sqrtPriceX96 >= c.minSqrtPriceX96 && c.sqrtPriceX96 <= c.maxSqrtPriceX96, "live price outside owner band"
        );
        require(c.deadline >= block.timestamp, "deadline");
        (int24 lower, int24 upper) = ticks(c.preset);
        if (c.preset == Preset.B) {
            require(
                c.sqrtPriceX96 > TickMath.getSqrtPriceAtTick(lower)
                    && c.sqrtPriceX96 < TickMath.getSqrtPriceAtTick(upper),
                "B is not in range at live price"
            );
        }
        if (c.preset == Preset.C) {
            require(c.ethMax == 0 && c.ogMax != 0, "C requires OG only");
            require(c.sqrtPriceX96 >= TickMath.getSqrtPriceAtTick(upper), "C is not OG-only at live price");
        }
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            c.sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), c.ethMax, c.ogMax
        );
        require(liquidity != 0, "zero liquidity for amounts/range");
        PoolKey memory key = c.hook.poolKey();
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lower, upper, uint256(liquidity), c.ethMax, c.ogMax, c.recipient, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        // PositionManager receives ethMax up front. Return unused native ETH atomically.
        params[2] = abi.encode(key.currency0, c.recipient);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPoolInitializer_v4.initializePool, (key, c.sqrtPriceX96));
        calls[1] = abi.encodeCall(IPositionManager.modifyLiquidities, (abi.encode(actions, params), c.deadline));
    }

    function run() external virtual {
        require(block.chainid == 1, "mainnet only");
        OGClubHook hook = OGClubHook(payable(vm.envAddress("HOOK")));
        require(!hook.opened(), "already opened");
        require(hook.INITIALIZER() == Networks.OWNER, "initializer mismatch");
        require(address(hook.poolManager()) == Networks.MANAGER && hook.OG() == Networks.OG, "pool mismatch");
        require(hook.VAULT() == Networks.VAULT && hook.VAULT_BPS() == 10000, "vault mismatch");
        require(uint160(address(hook)) & 0x3fff == 0x20cc, "flags");
        uint256 ethMax = vm.envUint("ETH_MAX_WEI");
        uint256 ogMax = vm.envUint("OG_MAX_WEI");
        require(ethMax <= type(uint128).max && ogMax <= type(uint128).max, "amount too large");
        uint256 preset = vm.envUint("PRESET");
        require(preset <= uint256(Preset.C), "preset 0=A 1=B 2=C");
        // The owner states the sqrtPriceX96 band they accept; a drifted or pushed old pool refuses to open.
        uint256 minPrice = vm.envUint("MIN_SQRT_PRICE_X96");
        uint256 maxPrice = vm.envUint("MAX_SQRT_PRICE_X96");
        require(minPrice <= type(uint160).max && maxPrice <= type(uint160).max, "band too large");
        (uint160 price,,,) = IStateView(Networks.STATE_VIEW).getSlot0(PoolId.wrap(Networks.OLD_POOL_ID));
        require(price != 0, "old pool not initialized");
        uint256 deadline = block.timestamp + 15 minutes;
        (bytes[] memory calls, uint128 liquidity) = build(
            OpenConfig(
                hook,
                price,
                uint160(minPrice),
                uint160(maxPrice),
                uint128(ethMax),
                uint128(ogMax),
                deadline,
                Preset(preset),
                Networks.OWNER
            )
        );
        console2.log("live old-pool sqrtPriceX96", price);
        console2.log("owner band min", minPrice);
        console2.log("owner band max", maxPrice);
        console2.log("liquidity", liquidity);
        console2.log("owner must be transaction origin", Networks.OWNER);
        vm.startBroadcast(Networks.OWNER);
        if (ogMax != 0) {
            require(IERC20(Networks.OG).approve(Networks.PERMIT2, ogMax), "ERC20 approval failed");
            IAllowanceTransfer(Networks.PERMIT2)
                .approve(Networks.OG, Networks.POSITION_MANAGER, uint160(ogMax), uint48(deadline));
        }
        IPositionManager(Networks.POSITION_MANAGER).multicall{value: ethMax}(calls);
        vm.stopBroadcast();
        require(hook.opened(), "opening did not complete");
    }
}
