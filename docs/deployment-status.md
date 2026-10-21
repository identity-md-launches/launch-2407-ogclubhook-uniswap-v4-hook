# Deployment status

No live transaction was signed or broadcast in this work. There is no live mainnet hook address or deploy transaction to report, and no live Sepolia rehearsal receipt. Etherscan verification is not submitted. No mainnet pool or liquidity position was created by this work.

Read-only public RPC access was available. Both named vaults returned the exact intended token address. The real deployed mainnet and Sepolia protocol contracts were exercised through pinned **local fork simulations**. This distinction is deliberate: a fork-created address, transaction trace, or simulated vault balance is not on-chain deployment evidence.

| Deliverable | Status |
|---|---|
| Hook and fixed-configuration CREATE2 deployer | Implemented and locally tested |
| Actual-deployer salt mining and address/flag assertions | Implemented; tested before broadcast |
| Owner OpenPool script, all three presets | Implemented; atomic init/mint tested |
| Mainnet fork at block 26242828 | Passed; see checks record |
| Sepolia fork at block 11964302 | Passed; see checks record |
| Live Sepolia hook/rehearsal transaction receipts | Outstanding deployment-service step |
| Live Sepolia vault balance before/after | Outstanding; fork values recorded separately |
| Live mainnet hook address, deployment receipt, exact numeric PoolKey | Outstanding deployment-service step |
| Etherscan verification links | Outstanding after live deployment |
| Mainnet opening/liquidity | Reserved for the initializer wallet, intentionally excluded from hook deployment |
| Independent contributor audit/release approval | Outstanding |

The deployment service must use the fixed configuration in README, obtain the actual `OGClubHookDeployer` address, mine its salt, confirm local and on-chain init-code hashes, simulate, and broadcast `deploy(salt, expected)`. The constructor and deployer both enforce the required 0x20cc permission pattern. No guessed address, unmined hook, private key, or launch manifest is included.

After deployment, record the actual `HookDeployed` transaction (including a prior identical permissionless deployment if one raced the call), confirmed address, all constructor arguments, salt, init-code hash, runtime code comparison, Etherscan links, `poolKey()`, and `POOL_ID()`. Only then deliver the numeric PoolKey to the original initializer for the separate owner-run opening.
