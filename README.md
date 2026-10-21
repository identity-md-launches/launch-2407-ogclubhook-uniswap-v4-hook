# OGClubHook

A Uniswap v4 hook for the existing OG token. One hook instance supports exactly one native ETH/OG PoolKey: static 1% LP fee, tick spacing 200, and an immutable 1% ETH club fee. The mainnet configuration uses all club fees to buy OG and transfer it directly from PoolManager to the existing OG Club farm vault.

**Deployment status:** implementation, vendored dependencies, local tests, and pinned mainnet/Sepolia fork rehearsals are delivered. **No live deployment or rehearsal transaction has been broadcast, no mainnet pool has been opened, and Etherscan verification has not been submitted.** This workspace supplies no transaction-signing capability. Live deployment and receipt collection remain with the deployment service. See [deployment status](docs/deployment-status.md), [checks](docs/checks.md), and [review](docs/independent-review.md). Fork-created addresses are not live deployment addresses.

## Build and test

Everything required to compile is ordinary source under `lib/`; there are no submodules, package-install steps, FFI calls, or Foundry filesystem grants. Compiler settings are pinned in the root `foundry.toml`: Solidity **0.8.26**, Cancun, optimizer 200 runs, `via_ir = true`, `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421 forge test
forge fmt --check
python3 tools/export_abis.py
```

The normal suite is offline and needs no application environment variables. The two fork tests skip by default. They opt in through Foundry's CLI, assert the pinned block, and use the actual deployed PoolManager, PositionManager, Universal Router, Permit2, token, and vault:

```sh
FOUNDRY_FUZZ_SEED=0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421 forge test \
  --match-contract MainnetForkTest --fork-url "$MAINNET_RPC_URL" \
  --fork-block-number 26242828 --no-storage-caching -vv
FOUNDRY_FUZZ_SEED=0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421 forge test \
  --match-contract SepoliaForkTest --fork-url "$SEPOLIA_RPC_URL" \
  --fork-block-number 11964302 --no-storage-caching -vv
```

Fork tests give their local actors test balances and advance simulated timestamps. They never sign or broadcast transactions. The local vault integration uses the unmodified `OGClubFarmVault.sol` from `identity-md-launches/launch-2398-continue-delivered-og-club` at `c77c19241414f82b5eb4d84b4720cce40741874d`, exclusively in `test/vendor/`. Dependency provenance and archive hashes are in [dependencies.json](docs/dependencies.json).

## Fixed mainnet configuration

| Parameter | Value |
|---|---|
| Chain | Ethereum, 1 |
| OG, 18 decimals | `0xCe7EB1Ad9e2E1c784ea05F7eA4A0Fe625923D10A` |
| Farm vault | `0x60401e748d6c3a1f2775bE9e6a41bda20eDa0B80` |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| StateView | `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227` |
| Universal Router | `0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af` |
| PositionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Owner, treasury, initializer | `0x5b95A971B4583A5f011E9DA082acdD679b870D06` |
| `VAULT_BPS` | `10000` |
| Old PoolId, for opening-price read | `0x5f95e64cf8e8f4e4376c1d97b5959dc479abf7b191ba0b286faeb2ec4180a2f9` |

The additional PositionManager and Permit2 addresses are from [Uniswap's deployment table](https://github.com/Uniswap/docs/blob/main/content/protocols/v4/deployments.mdx) and were exercised on the pinned fork. The token returned by each named vault was also checked by public RPC. The similarly named token `0xf58a132967eF5eb52947031C86663Df5779ee2C6` is **not** this pool's OG. Names and symbols are not identity checks.

The hook constructor is `(manager, og, vault, vaultBps, owner, treasury, initializer)` in that order. It rejects a wrong `vault.token()` whenever `vaultBps > 0`, out-of-range basis points, and zero required addresses. The PoolKey returned by `hook.poolKey()` is exactly:

```text
currency0 = 0x0000000000000000000000000000000000000000  (native ETH)
currency1 = 0xCe7EB1Ad9e2E1c784ea05F7eA4A0Fe625923D10A
fee        = 10000
tickSpacing = 200
hooks      = the confirmed OGClubHook deployment address
```

`POOL_ID` is `keccak256(abi.encode(PoolKey))`. A complete numeric PoolKey and PoolId must be recorded after the actual CREATE2 deployer and salt are known. This repository deliberately does not invent that address.

## Fees and custody

The LP fee is v4's fixed `10000` fee tier (one million fee units per whole). Club fees use basis points (ten thousand per whole). They are separate components with different bases; the aggregate is not exactly 2.00% in every mode.

| Trade | ETH club fee | Hook delta |
|---|---|---|
| Buy, exact ETH input `in` | `floor(in * 100 / 10000)` | `beforeSwap`, positive specified delta |
| Buy, exact OG output | `floor(actualPoolEthIn * 100 / 9900)` | `afterSwap`, positive unspecified delta |
| Sell, exact OG input | `floor(grossPoolEthOut * 100 / 10000)` | `afterSwap`, positive unspecified delta |
| Sell, exact net ETH output `net` | `ceil(net * 10000 / 9900) - net` | `beforeSwap`, positive specified delta |

ETH-specified partial fills revert atomically, including the fee mint. OG-specified partial fills use the actual executed ETH amount. All callers, including owner, initializer, treasury and vault, pay the same fee. Tiny trades may round the fee down to zero.

Fees are minted as PoolManager ERC-6909 native-currency claims, id `0`, owned by the hook. There is **no `take` during a user swap**. The hook neither receives OG from a swap nor approves OG to anyone. Its flush sends OG directly to `VAULT` with `PoolManager.take`. Unsolicited ERC-20 transfers cannot be prevented and have no recovery path.

## Flush behavior

Anyone pays gas to call `flush()`. It is guarded against reentrancy and rejects every call while PoolManager is unlocked, including calls during swap settlement. The first flush is available 600 seconds after initialization, and each successful flush starts another 600-second interval. A reverted flush does not consume the interval. A successful empty or below-minimum flush does.

For the current claim balance `C`:

1. `vaultPart = floor(C * VAULT_BPS / 10000)`; `clubPart = C - vaultPart`.
2. Read active liquidity `L` and current `sqrtPriceX96`. Compute virtual ETH reserve `floor(L * 2^96 / sqrtPriceX96)`.
3. Buy with the minimum of `vaultPart`, 0.5% of that virtual reserve, and 0.5 ETH. Skip buying if `L == 0`, the result is below 0.0001 ETH, or a usable price limit cannot be formed.
4. Swap ETH to OG, retaining the 1% LP fee. v4 automatically suppresses hooks when the hook itself calls `swap`; no user-accessible exemption exists.
5. Permit partial execution. Burn only `ethSpent + clubPart`, transfer OG directly to the vault, and send the club ETH to the treasury. The remainder stays in ERC-6909 claims.

The price limit uses `ceil(sqrtPriceX96 * 990147542976674310 / 1e18)`, bounded by v4's minimum. That rounded-up factor is `1 / sqrt(1.02)`: ETH per OG increases by at most 2%, and OG per ETH decreases by at most 1.960785%. Both price denominations therefore satisfy the 2% ceiling. This is a limit on the flush's move from its **execution-time spot price**, not an oracle guarantee.

A treasury payment receives at most 50,000 gas. If it rejects, exhausts that gas, or attempts a reverting reentrant call, the vault funding can still succeed; the failed payment is recorded in `heldEth` and `FlushDeferred`. Future successful flushes retry all deferred ETH to the then-current treasury. There is no separate withdrawal or sweep. With the mainnet 10000 split no treasury amount accrues.

**Split semantics:** the requested formula applies to the whole remaining claim balance at each flush. For a 5000 split, previously unspent vault claims are split again on the next call. For example, 2 ETH in claims becomes a 0.5 ETH buy, 1 ETH treasury payment, and 0.5 ETH remaining; the next flush splits that remainder 0.25/0.25. A 5000 setting is therefore not a guaranteed lifetime 50/50 distribution when caps or minimums bind. Mainnet's 10000 split is unaffected.

Views: `pendingFees()` reports ERC-6909 claims only; `heldEth()` reports failed treasury ETH; `nextFlushAt()` gives the timestamp gate; `previewBuy()` returns `(ethToBuy, sqrtPriceLimitX96)` using current spot state, regardless of the time gate. `totalFees`, `totalSpent`, and `totalFlushed` provide accounting for normal fee flows. Under those flows:

```text
pendingFees + heldEth + totalSpent + totalFlushed == totalFees
```

Directly donated ERC-6909 claims or forced ETH are outside that equality: they are not swap fees. Donated native claims are processed by the same flush rules; forced/unrequested ETH and OG have no sweep. Keepers should monitor the normal accounting identity, claim backlog, `nextFlushAt`, liquidity, and `FlushDeferred`. There is no keeper reward and no guaranteed flush schedule.

## Permissions, risks, and ownership

Exactly five permission flags are enabled: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. The low 14 address bits must be **0x20cc**. The constructor validates this; mining is mandatory.

`beforeInitialize` accepts only the exact key, once, with `tx.origin == INITIALIZER`. This is the only `tx.origin` use and deliberately allows the owner's PositionManager multicall. The initializer must be the transaction-origin wallet, not a Safe, relayer or smart-account address whose actual origin differs. The owner must inspect any transaction that calls third-party contracts: the origin gate cannot distinguish a deliberately approved opening from an opening induced by a malicious intermediary.

OpenZeppelin `Ownable2Step` supports propose/accept ownership transfer and renunciation. The hook's sole application-level owner setter is `setTreasury(nonzero)`, disabled when `VAULT_BPS == 10000`. There are no fee, split, vault, initializer, cap, pause, sweep, execution, upgrade, proxy, delegatecall or selfdestruct powers. Changing or renouncing ownership does not change `INITIALIZER`, stop swaps, or stop flushes. Renouncing a partial-split hook while its treasury permanently rejects ETH can leave deferred funds stuck until that treasury accepts ETH.

Sandwich tests execute buy/flush/sell and sell/flush/buy cycles from 0.1% to 50% of active virtual reserves, including a 500-point grid and fuzzed liquidity. In that model the capped buy's benefit is smaller than the attacker's round-trip fees; profit is nonpositive even before gas and borrowing costs. This is **not a universal MEV proof**: the tests exclude outside venues, exogenous repricing, attacker LP ownership, JIT liquidity, and collusion with vault beneficiaries. A spot price is manipulable, and the limit does not compare it to fair value. Keepers may use private transaction submission. See the [review scope and limitations](docs/independent-review.md).

LPs face impermanent loss, inventory concentration and out-of-range risk. The club fee belongs to the vault/treasury split, not to LPs. The original pool remains open and independent: no migration, volume guarantee, token tax, bonding curve, or new token is created. Traders and routers can split or divert volume based on depth, execution price, and total cost. Only swaps through this exact new PoolKey generate these club fees. Protocol-level v4 fee governance remains outside the hook's control.

## Deploying without opening the mainnet pool

The generic launch factory cannot choose a hook-permission address for a direct `OGClubHook` deployment. The launch application is **`OGClubHookDeployer`**, with the same seven constructor arguments from the table above. Its constructor makes no external calls and needs no existing dependencies on an empty-chain deployment probe. It embeds the compiled hook and exposes a fixed-configuration CREATE2 deployment; the hook's required live vault check occurs in that deployment. Do not directly list `OGClubHook` for arbitrary-salt factory deployment. The manifest is a later deployment-service artifact and is not supplied here.

`OGClubHookDeployer` has no admin. Anyone can deploy a valid salt with its fixed immutable owner and beneficiaries, and repeating the same salt returns the existing hook. Another caller cannot change the parameters or block one salt by deploying a different salt. Opening any resulting hook still requires the immutable initializer.

The deployment service may create this deployer through its launch factory. Alternatively the delivered script's `deployDeployer()` entry point creates the identical configuration. Review/simulate each command without `--broadcast` first; signing uses the deployer's supplied account, never a committed key.

```sh
forge script script/DeployHook.s.sol:DeployHook --sig 'deployDeployer()' \
  --rpc-url "$MAINNET_RPC_URL" --account "$DEPLOY_ACCOUNT" --broadcast
```

Set `HOOK_DEPLOYER` to the confirmed address from that receipt. Mine for **that** contract, not the EOA, the IMD outer factory, a test fixture, or Foundry's default CREATE2 proxy:

```sh
forge script script/MineSalt.s.sol:MineSalt --sig 'run(address,uint256,uint256)' \
  "$HOOK_DEPLOYER" 0 1000000 --rpc-url "$MAINNET_RPC_URL"
```

Record the printed `SALT`, `HOOK`, and init-code hash. No signing is needed to mine. Exhausting the bounded search reverts without deploying; continue with another start index. The deploy script independently recomputes the address from its local build, checks the live deployer's full configuration and init-code hash, and asserts all permission bits **before** `startBroadcast`:

```sh
forge script script/DeployHook.s.sol:DeployHook --sig 'run(address,bytes32,address)' \
  "$HOOK_DEPLOYER" "$SALT" "$HOOK" \
  --rpc-url "$MAINNET_RPC_URL" --account "$DEPLOY_ACCOUNT" --broadcast
```

Record the `HookDeployed` receipt, exact address, salt, constructor arguments, compiler settings, `poolKey()`, and `POOL_ID()`. Do not broadcast if any address/hash/flag check fails. These commands contain no mainnet initialization or liquidity call.

Verify both the deployer and the hook with Etherscan using this checkout and the same constructor arguments. For the hook:

```sh
CONSTRUCTOR_ARGS=$(cast abi-encode 'constructor(address,address,address,uint256,address,address,address)' \
  0x000000000004444c5dc75cB358380D2e3dE08A90 \
  0xCe7EB1Ad9e2E1c784ea05F7eA4A0Fe625923D10A \
  0x60401e748d6c3a1f2775bE9e6a41bda20eDa0B80 10000 \
  0x5b95A971B4583A5f011E9DA082acdD679b870D06 \
  0x5b95A971B4583A5f011E9DA082acdD679b870D06 \
  0x5b95A971B4583A5f011E9DA082acdD679b870D06)
forge verify-contract "$HOOK" src/OGClubHook.sol:OGClubHook \
  --chain 1 --constructor-args "$CONSTRUCTOR_ARGS" --watch
forge verify-contract "$HOOK_DEPLOYER" src/OGClubHookDeployer.sol:OGClubHookDeployer \
  --chain 1 --constructor-args "$CONSTRUCTOR_ARGS" --watch
```

Supply Etherscan credentials to the deployment operator's environment. Successful compilation or a fork simulation is not explorer verification. Preserve the final verification links in the deployment record.

## Owner: opening the pool later

Only the original initializer wallet (`0x5b95…0D06`) performs this step. The hook deployment does not open the pool. Obtain OG and native ETH, choose a range, and set maximum raw token amounts in the caller's environment; both assets have 18 decimals.

| `PRESET` | Range | Intended use |
|---|---|---|
| `0` (A) | `-887200 .. 887200` | Full usable range for spacing 200 |
| `1` (B) | `172600 .. 186600` | Concentrated range; inventory and active status depend on live price |
| `2` (C) | `165600 .. 179400` | OG-only; requires `ETH_MAX_WEI=0` and live price at/above the upper tick |

Set `HOOK` to the confirmed mainnet hook, `ETH_MAX_WEI` and `OG_MAX_WEI` to the owner's chosen amounts, and `PRESET` to 0, 1, or 2. No example amount is silently used as a default.

```sh
forge script script/OpenPool.s.sol:OpenPool --rpc-url "$MAINNET_RPC_URL" \
  --sender 0x5b95A971B4583A5f011E9DA082acdD679b870D06 \
  --account "$OWNER_ACCOUNT"
# After reviewing that simulation, run the same command with --broadcast.
```

The script reads the old pool's live `sqrtPriceX96` from StateView, computes liquidity from the chosen caps, approves only the chosen OG amount to Permit2, gives PositionManager a Permit2 allowance expiring in 15 minutes, and sends **one PositionManager multicall containing initialization plus mint** with the same deadline. Unused native ETH is refunded atomically; the LP NFT goes to the initializer. A failed mint rolls back initialization. Approvals are separate prerequisite transactions and can remain if opening fails; the ERC-20 approval to Permit2 has no expiry and may be revoked by the owner.

The read is made when preparing the broadcast; it is not an on-chain oracle lock on the old pool. Re-run the script if the quote gets stale; the old pool may move before inclusion. In preset C, active liquidity starts at zero while the price is above the range, so flush buying skips until active liquidity exists. An ETH buy may cross into the range. The script refuses C when the live price would require ETH.

## Sepolia live rehearsal and ongoing flushing

The Sepolia script pins MockOG `0x7B5488Aa00c86D3364458Df50b498A1356d7C846`, vault `0x554Fd2a38CBa59Ef5359F1Db8E3d615c408aE3A2`, PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, and PositionManager `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4`. It rejects other chain IDs. It has separate entry points, so there is no sleeping process and no pretend timestamp change on the live chain:

1. `deployDeployer(address rehearsalOwner)` using a supplied funded Sepolia signer; that owner becomes the initializer and treasury.
2. Mine with `MineSalt.run(actualSepoliaDeployer, start, attempts)` and call `deployHook(address,bytes32,address)`.
3. `open(address hook,uint160 price,uint128 ethMax,uint128 ogMax)`, signed by that initializer. The explicit rehearsal price is caller-supplied; the fork test uses `2^96` (1:1) solely as a test price.
4. `swap(address hook,bool ethToOg,uint128 amount,uint128 minOut)` through the live Universal Router; use nonzero slippage limits for both a buy and a sell. Keep enough fees and liquidity for `previewBuy()` to reach 0.0001 ETH.
5. At or after the reported `nextFlushAt`, run `finish(address hook)`. It records vault balance before/after and verifies the delta equals OG output, with hook OG balance zero.

Each is invoked with `forge script script/SepoliaRehearsal.s.sol:SepoliaRehearsal --sig '<entry point>' <arguments> --rpc-url "$SEPOLIA_RPC_URL" --account "$REHEARSAL_ACCOUNT"`, adding `--broadcast` only for the actual live run. Store the actual transaction receipts and vault deltas before marking a live rehearsal complete. This assignment's supplied evidence is explicitly a fork rehearsal.

After the owner has opened mainnet, any keeper can simulate and then broadcast:

```sh
forge script script/Flush.s.sol:Flush --sig 'run(address)' "$HOOK" \
  --rpc-url "$MAINNET_RPC_URL" --account "$KEEPER_ACCOUNT" --broadcast
```

The vault's owner separately proposes Merkle seasons and farmers claim through the existing vault. A plain transfer funds available rewards; it does not propose or immediately distribute a season. The hook has no vault administration authority.
