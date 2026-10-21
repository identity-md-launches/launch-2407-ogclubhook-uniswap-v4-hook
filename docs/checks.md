# Local check record — 2026-10-21

These are author-run checks, not independent audit authority or live deployment receipts.

| Check | Result |
|---|---|
| `forge build` | Pass, Solidity 0.8.26, Cancun, optimizer 200, via IR, bytecode hash none |
| `forge test --offline -vv` with the requested fuzz seed | 66 passed, 0 failed; 2 optional fork tests skipped |
| `forge fmt --check` | Pass |
| Fee fuzz | 256 cases across all four modes |
| Bidirectional sandwich fuzz | 256 cases per direction, 0.1%–50% of active virtual reserves |
| Sandwich grid | 500 buy/flush/sell sizes, 0.1% through 50% in 0.1% increments |
| Stateful conservation | 64 runs × 32 calls = 2048 actions, zero reverts |
| Mainnet pinned fork | Pass at block 26242828 |
| Sepolia pinned fork | Pass at block 11964302 |
| ABI export | Both delivered JSON ABIs equal their compiled artifact ABIs |
| Library linking | No unresolved creation/runtime link references in either application |
| Runtime opcode/size probe | Pass for both application contracts |
| Source and vendor layout | Ordinary files, no submodules/symlinks, no test env reads, no FFI/filesystem grants |

The exact fuzz seed used was:

```text
0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421
```

Foundry reports generic static lint warnings; their relevance and safeguards are discussed in [independent-review.md](independent-review.md). Compilation and all default tests return success.

## Pinned fork evidence

The final fork checks used the real deployed protocol contracts and the same hook/deployer production sources identified below. They initialize a **fork-local** pool via PositionManager, trade both directions through the real Universal Router, flush, and exercise proposal/claim on the live vault's forked storage. Actor balances and elapsed time are simulated with test cheatcodes. No transactions were sent to either chain.

| Field | Ethereum fork | Sepolia fork |
|---|---|---|
| Block | 26242828 | 11964302 |
| Block hash | `0xba4af60f46e342701cdac914314c80888ddf5e6f2c40cf0cf62f55869acdc414` | `0x51bc2b66b31cce4a45e243490e47bd0e74595d3a5a3ae771c3d38fe8fb7960b6` |
| Vault OG before, raw 18-decimal units | `0` | `350000000000000000000000` |
| Vault OG after simulated flush | `18348709440971401982208` | `350000000291609810720921` |
| OG delivered by simulated flush | `18348709440971401982208` | `291609810720921` |
| ETH spent by simulated flush, wei | `297507831293916` | `297507831293916` |
| Hook OG after flush | `0` | `0` |
| Permission bits | `0x20cc` | `0x20cc` |
| Actual live deploy/rehearsal transaction | None | None |

Reproduction:

```sh
FOUNDRY_FUZZ_SEED=0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421 forge test \
  --match-contract MainnetForkTest --fork-url https://eth.drpc.org \
  --fork-block-number 26242828 --no-storage-caching -vv
FOUNDRY_FUZZ_SEED=0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421 forge test \
  --match-contract SepoliaForkTest --fork-url https://ethereum-sepolia-rpc.publicnode.com \
  --fork-block-number 11964302 --no-storage-caching -vv
```

An archive-capable endpoint is needed as these blocks age. The initial mainnet run succeeded through PublicNode; a later repeat returned `historical state ... is not available` before executing application code. The final mainnet repeat passed through dRPC at the **same** block. This was an RPC availability failure, not a changed test or an unpinned fallback. Public RPC availability is not guaranteed for future reproductions; use another archive endpoint if needed.

Additional read-only observations, including contract byte lengths, SHA-256 hashes of on-chain runtime bytes, exact `vault.token()` results and token decimals, are in [network-observations.json](network-observations.json). These hashes identify observations; they are not a source-verification attestation.

## Reproducible artifacts

| Contract | Creation bytecode bytes, excluding args | Runtime bytes | EIP-170 limit |
|---|---:|---:|---:|
| OGClubHook | 10517 | 9107 | 24576 |
| OGClubHookDeployer | 12981 | 12425 | 24576 |

The static seven-argument constructor encoding adds 224 bytes to either creation bytecode. Both remain below the 49152-byte init-code limit. Hook runtime immutables and its CREATE2 address depend on the actual constructor values; the source hashes below are **not** deployment bytecode hashes.

```text
src/OGClubHook.sol SHA256
1942dbf71181c71e6e1828e4e13f7d846334511f413b960881913b07ba4274d2

src/OGClubHookDeployer.sol SHA256
444c296d7e1cb60eef17902ee2cc41666031382d6559fea13b1075b7163a0033

abi/OGClubHook.json SHA256
ed52392be775d89cbeef0c2e3c4bd61a910ff0a2e3cfd737d7caca31b634722c

abi/OGClubHookDeployer.json SHA256
f11d1f81fcc8c94c32e5208c3793f28ce5d4565062a7b1560830c34ee1c0d276

test/vendor/OGClubFarmVault.sol SHA256 (unchanged pinned upstream source)
86dc5e5368edcbed1ce22400096a2f24f2f23707fd29de42abf8214cdd8ad6d1
```

The default local PositionManager tests use its actual vendored implementation and a narrowly scoped Permit2 allowance fixture; they do not test Permit2 signatures. Both fork rehearsals use the real deployed Permit2 instead. The real vault integration is neither a replacement mock nor production-deployed source from this repository.

Live mainnet deployment, live Sepolia receipts, Etherscan verification and independent release review are outstanding, as recorded in [deployment-status.md](deployment-status.md).
