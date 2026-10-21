# Additional OGClubHook test coverage

This contribution adds tests only. Production contracts, deployment scripts, dependency files, and configuration are unchanged. The tests use the existing vendored Uniswap v4 PoolManager and farm vault, and need no downloads, FFI, environment mutation, or RPC for their default run.

## Properties and oracles

| File | Added checks |
| --- | --- |
| `AdversarialFees.t.sol` | All four trade modes against an otherwise identical unhooked pool at ticks 0 and 180000. Compare actual ETH/OG settlement, pool price/tick, LP fee growth, claims, and ClubFee event contents. Exercise one-wei trades and rounding boundaries; reject zero, int128/int256 overflows, gross-output overflow, absent ETH settlement, absent OG approval, and ETH partial fills without leaving fees or price changes. |
| `AdversarialLifecycle.t.sol` | Initialization rollback; exact pool-key and callback authorization failures; failed OG transfers roll back claim burns, counters, cooldown and pool state; immediate retry; event-to-balance agreement; repeated treasury rejection and one-time repayment; minimum-buy dust; odd splits; pending-owner and renunciation restrictions; every zero constructor address and token-validation boundaries. |
| `AtomicRouting.t.sol` | Four swaps in a single real PoolManager unlock with net settlement. Mid-unlock flush calls must fail. A failed late swap must roll back every earlier swap and fee mint, and the next transaction must succeed without stale transient debt. |
| `ReferenceState.t.sol` | The time-weighted flush reference (`referenceState`, and the depth and price limit it feeds into `previewBuy`/`flush`), checked against a segment model built only from PoolManager reads taken at each observation point. Sequences of 16 random swaps (all four modes), liquidity adds and removes, warps, and on-time or early flushes. Pinned cases: depth never seen by a swap earns nothing; liquidity removed after the last swap counts against the whole gap; added liquidity earns only from its first observation; a spot more than 2% below the reference skips the buy, keeps the claims and restarts the window. A scripted sequence makes sure the model reaches buying flushes. |
| `StatefulLifecycle.t.sol` | Three actors and two treasuries across all-vault, half-vault and all-treasury configurations. Random swaps, dust trades, flush timing, complete liquidity removal/restoration, treasury rejection/rerouting, ownership handover and renunciation. |

The stateful fee oracle reads the PoolManager's raw Swap events, emitted before the hook's afterSwap adjustment. It does not derive expected fees from the hook's counters. Independent ghost totals are compared to actual claim balances, held ETH, treasury balances, vault token receipts, and trader settlement. Claims + held ETH + ETH spent + ETH paid must equal externally calculated fees after every sequence. The suite also checks the immutable initializer, ownership state, cooldown, liquidity, and settlement of every manager delta.

Each added fuzz function runs 1,000 cases. Each new invariant runs 256 sequences of 64 calls with unexpected reverts treated as failures: 49,152 calls across the three splits. Settings are on concrete test functions because inherited inline configuration was not applied by the local runner. Deterministic handler tests separately exercise every trade mode, successful and rejected flushes, empty liquidity, deferred payment, and operation after renunciation.

The new tests use the supplied Pashov fizz, Trail of Bits property-based-testing, and eth-testing references as testing guidance. The harness and assertions are project-specific original code, not copies of their templates.

## Reproduction

Run from the repository root:

```sh
FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
  forge build --offline

FOUNDRY_OUT=test/scratch/out FOUNDRY_CACHE_PATH=test/scratch/cache \
  FOUNDRY_FUZZ_SEED=0x0830a7a9061eb20b0e55b610dc2f46402c7696f31bc79095056e83d54a7d8421 \
  forge test --offline
```

The output/cache overrides keep generated files inside disposable scratch space. No delivered test imports or depends on anything there.

Validation on this contribution: `forge build --offline` passed; the full seeded offline suite passed with **117 tests, 0 failures, 2 optional fork skips**, against the implementation that adds the time-weighted reference and pays the treasury after PoolManager relocks. In this revision, `test_oneWeiBelowMinimumIsRetainedUntilNewFeeReachesThreshold` now expects a zero preview within the flush second. That is the documented behaviour of the new reference window. The test checks the threshold buy once the cooldown has passed. The existing `MainnetForkTest` also passed separately at block **26242828**: simulated vault OG increased from 0 to 18348709440971401982208 raw units, with 297507831293916 wei spent. The Sepolia fork was not rerun in this contribution. No reproducible production defect was found by these added checks.

## Boundaries

The reference-window design lets anyone who calls `flush` right after pushing spot more than 2% below the reference skip that window's vault buy and restart the 600 s clock. The claims are kept, and the push costs the caller LP and club fees both ways. This is a liveness trade-off of the agreed anti-sandwich design, not a loss of funds, so it is tested (`test_flushSkipsBuyWhenSpotIsFarBelowReferenceAndRestartsWindow`) rather than reported as a defect.

The random-sequence model tracks swap fees, not unsolicited ERC-6909 claim gifts or forced ETH/token transfers. The stateful treasury fixtures either accept or reject ETH; existing tests separately cover gas exhaustion and reentrancy. The isolated failed-token-transfer test mocks only that external transfer, then clears the mock and exercises a real retry.

Existing tests continue to cover sandwich scenarios, concentrated-liquidity partial flushes, the 2% limit, LP operations, PositionManager opening, and real farm-vault proposals and claims. The existing sandwich model excludes external trading venues and attacker-owned liquidity; these tests do not establish a universal MEV-profit bound.

The two existing pinned fork tests remain optional and skip by default. A fork simulation is not a live Sepolia rehearsal, deployment, or Etherscan verification. No broadcasts are performed by this test contribution.
