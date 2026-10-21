# Review handoff

**Status: author adversarial review completed; independent contributor review and release approval remain outstanding.** This file is an evidence-based handoff, not a claim that an independent audit has occurred. No outside auditor, Slither, or Mythril was used. No live release was performed.

The reviewed production surface is `src/OGClubHook.sol` and `src/OGClubHookDeployer.sol`, plus the deployment/open/flush scripts and the vendored libraries they import. Compiler: Solidity 0.8.26, optimizer 200, via IR, Cancun, metadata bytecode hash disabled. The actual farm vault source is test-only and unmodified at the requested revision.

## Concrete cases examined

| Case and expected result | Evidence |
|---|---|
| Arbitrary address has wrong hook flags: constructor reverts | `SecurityTest.test_badHookAddressRejectedByConstructor` |
| Different token/fee/tick spacing with the same hook cannot initialize | `test_wrongCurrencyFeeSpacingOrHookCannotOpen` |
| Sender matches initializer but origin does not: opening fails | `test_initializerGateUsesOriginThroughRouter`, `OpenPoolTest` |
| Every callback rejects a non-PoolManager caller | `test_callbacksRequirePoolManager`, unsolicited unlock test |
| A same-symbol wrong OG vault cannot deploy when vault share is positive | `test_wrongTokenVaultRevertsEvenIfSymbolIsOg` |
| Fee delta sign/currency and rounding for four trade modes | `FeesTest`, including the requested fixed fuzz seed |
| ETH-specified partial execution cannot mint a surviving excess fee | Both partial-fill rollback tests; raw pool price and claims remain unchanged |
| An OG-specified partial fill uses actual ETH only | Both OG partial-fill tests |
| LP operations neither charge club fees nor invoke liquidity hooks | `test_lpAddRemoveUntouched`, stateful LP actions |
| Self-swap pays LP fee and emits no club-fee event | `test_flushFundsRealVaultDirectlyWithoutSelfFee`, `test_flushStillPaysLpFee` |
| Caps, tiny values, zero liquidity and exact 600-second boundary | `FlushTest` |
| A narrow active range followed by a liquidity gap partially fills at the price limit | `test_narrowLiquidityGapPartialFlushUsesTwoPercentPriceLimit` |
| Rejection, gas exhaustion and reentrancy in a treasury cannot steal vault funds | Three dedicated treasury tests; failed payment remains `heldEth` |
| Flush during any manager unlock rejects | `test_midUnlockReverts`; checks transient manager lock state, not a vulnerable local swap flag |
| Treasury changes respect owner and split restrictions | `test_setTreasuryOnlyOwnerNonzeroAndDisabledAt100Percent` |
| Ownership handover requires acceptance; renunciation leaves operation possible | Both ownership/renunciation tests |
| No arbitrary fee, pause, sweep, execution or upgrade selectors | `test_noFeePauseSweepUpgradeOrGenericExecutionSelectors` |
| No reachable delegatecall, callcode or selfdestruct in application runtimes; size bounded | `test_runtimeSizeAndNoEscapeOpcodes`, matching the supplied deployment probe's scan |
| Permissionless factory callers cannot change fixed roles or block a different salt | `test_deployerRejectsWrongPredictionFlagsAndRepeat` |
| Wrong deployment chain, owner, deployer or salt fails before broadcast | `DeploymentScriptsTest` |
| Initialization and position mint revert together on failure | `OpenPoolTest.test_failedMintRollsBackPoolInitialization` |
| Whole-sequence conservation with rejects and liquidity changes | `AccountingInvariantTest`, independent fee/paid/spent counters |
| Real vault transfer funding, proposal delay and claim | `RealVaultTest`; deployed vault behavior also exercised on both pinned forks |

## Repairs made during this review

1. A deployer that stored only a single first-deployed hook would let a third party choose another salt first and block the intended salt. The delivered deployer uses a per-salt mapping and idempotent calls, while retaining immutable constructor parameters. No caller receives administration rights.
2. A 2% fall in OG/ETH permits more than a 2% rise in its reciprocal. The final limit uses `1/sqrt(1.02)`, rounded toward a tighter limit, so both denominations remain within 2%. The gap test checks both inequalities.
3. OpenPool previously checked the current mutable owner as well as the immutable initializer. The final script checks the initializer; transfer/renunciation cannot disable the original wallet's opening authority.
4. The upstream test LP router assumes that any positive liquidity deposit must create a net token debt. A valid tiny deposit after fee accrual violates that test-router assumption. The invariant harness now settles the actual signed deltas through PoolManager and tests fee conservation directly; production code was unaffected.
5. SepoliaRehearsal reuses OpenPool's transaction builder. Its default `run()` explicitly reverts so it cannot accidentally inherit the mainnet opening entry point. Each named rehearsal phase separately requires Sepolia.

## Security boundaries and residual risks

The PoolManager and fixed OG token are trusted protocol dependencies. `onlyPoolManager` protects callbacks, and the flush guard checks `TransientStateLibrary.isUnlocked`. A direct attacker cannot manufacture a fee-free self-swap: the only hook-originated swap is the fixed flush path. Hook data does not select destinations or exemptions. Claims are burned only against actual spent ETH and the computed club share; every manager currency delta is settled before unlock completes.

The 2% execution limit and 0.5% virtual-reserve cap do not establish an independent market price. A pool can be manipulated before a flush. The 500-point grid and bidirectional fuzz tests establish nonpositive standalone sandwich profit only for their stated model: restore OG inventory, no outside venue, no LP ownership, no exogenous price move, no vault-beneficiary collusion, no gas/loan costs. They are not a proof against every economic strategy. Independent review should examine concentrated-liquidity/JIT and cross-venue strategies separately before any claim of universal resistance.

The explicit origin initialization gate can be satisfied through any intermediary invoked by that wallet. This is required behavior and creates a transaction-review responsibility for the initializer. It is the sole production `tx.origin` use. Smart accounts or multisigs whose origin differs from their own address cannot serve as this gate's address without changing the agreed design.

For intermediate vault splits, unspent claims are split again on future calls. This follows the supplied algorithm exactly; it is not a lifetime allocation guarantee. A dedicated regression test makes the resulting 5000-split behavior visible. Mainnet uses 10000.

Treasury gas is bounded to 50,000. A recipient requiring more gas will defer even if otherwise legitimate. With a partial split, a renounced hook cannot change a permanently rejecting recipient. Successful no-op flushes consume the interval and can postpone accumulation of very small fees. There is no automated caller incentive or liveness promise.

ERC-6909 claim donations, forced ETH, and unsolicited OG are possible. Accounting counters track swap fees, not external gifts. The conservation invariant assumes no unsolicited assets; the production hook cannot guarantee an absolute zero ERC-20 balance against arbitrary senders. There is intentionally no recovery power.

OpenPool fetches the old pool's current slot0 while preparing its transaction. The old pool can change before mining; owners should refresh stale simulations and use the exact delivered deadline/amount caps. Preset C begins outside active liquidity at prices above its upper tick.

The constructor must call `vault.token()` for a positive share. Therefore generic empty-chain constructor rehearsal applies to the deployer application, not to a direct hook deployment. The live deployment must still validate actual dependencies and use the constructor-inclusive init-code hash of the final compiled hook.

## Static warnings assessed

Foundry reports generic warnings for the specified origin gate, timestamp gate, casts, events after protocol calls, and the gas-limited treasury call. Cast inputs are bounded to int128 swap amounts or nonnegative int128 deltas; the buy is capped at 0.5 ETH; the price multiplier is below one. The timestamp gate is an interval, not randomness. PoolManager ERC-6909 mint/burn have no recipient callback. Flush is guarded across all external calls. Unused treasury return data is not decoded. The CREATE2 hash concatenates fixed creation code with a fixed-length static constructor encoding, so the generic multiple-dynamic-arguments warning does not imply ambiguous configuration encoding.

These rationales do not replace independent validation of compiler output. The next reviewer should sign off the final sources, ABIs, constructor values, actual deployer and mined address, deployed-bytecode comparison, receipts, source verification, and the owner's separate pool-opening responsibility.
