# vault (VAULT)

`src/VaultToken.sol:VaultToken` is a fixed-supply ERC-20 token. Its constructor mints **1,000,000,000 VAULT** to the immediate deployer once. The name is lowercase `vault`, the symbol is uppercase `VAULT`, and balances use 18 decimals.

## Design and assumptions

- `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18`, or **1000000000000000000000000000** smallest units.
- The requested name describes an ERC-20 token. There are no deposit, redemption, yield, or ERC-4626 share functions.
- OpenZeppelin Contracts v5.2.0 supplies the standard ERC-20 implementation. There are no overrides to its transfer or allowance behavior.
- Transfers move the exact requested amount. There are no taxes, rebases, transfer limits, allowlists, or launch exemptions.
- The token has no owner, administrator, mint entry point, burn entry point, pause, confiscation, upgrade mechanism, proxy, or initialization step. Total supply remains constant after construction.
- The constructor makes no external calls and needs no deployed dependencies. Token operations make no external calls or recipient callbacks. There are no oracle, timestamp, block-number, chain-specific precompile, or randomness dependencies.

## Build and check

Run from the repository root with Foundry and Solidity **0.8.26** installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7d9599f26cf99b4d327e06d5e64b3b299370d8e5f84feb32f4323ccfee4a42a1 forge test
forge fmt --check
```

`foundry.toml` pins solc by version, targets Cancun, enables the optimizer with 200 runs, and sets `bytecode_hash = "none"`. All library source and license files required to build and test offline are vendored in `lib/`. Provenance is recorded in [DEPENDENCIES.md](DEPENDENCIES.md). No dependency installation, RPC, fork, environment-derived test configuration, FFI, or filesystem cheatcode access is needed. The command above supplies only Foundry's requested reproducible fuzz seed.

Tests cover metadata and exact issuance; direct and CREATE2 factory deployment; mint, transfer and approval events; exact, zero, full-balance and self-transfers; finite and unlimited allowances; replacement and revocation; unauthorized spending; invalid addresses; insufficient balance/allowance; rollback on failed transfers; and rejection of common administrative/mint/burn selectors. Five fuzz tests exercise deployment and transfer boundaries (512 cases each). Two stateful invariants compare all balances and allowances against an independent model over randomized transfer, approval, delegated-transfer and failed-overspend sequences (128 runs, depth 64).

The distribution smoke test exercises full-amount factory/distributor/pool token transfers, including both directions of a trade's token leg. It does not deploy an AMM or prove live liquidity provisioning. The supplied launch admission harness separately checks actual pool initialization, liquidity seeding and swaps against the final launch configuration.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity identifier | `VaultToken` |
| Fully qualified artifact | `src/VaultToken.sol:VaultToken` |
| Constructor arguments | None (`[]`) |
| Native value sent to constructor | `0` (nonpayable) |
| Name / symbol / decimals | `vault` / `VAULT` / `18` |
| Total supply in smallest units | `1000000000000000000000000000` |
| Initial recipient | Immediate creator (`msg.sender`) |
| Assignment launch chain | Robinhood Chain, chain ID `4663` |
| Application contracts | None |
| Post-deployment initialization | None |

The authorized launch system deploys the artifact directly through its factory. The factory receives the entire supply; the wallet calling that factory does not receive tokens from the constructor. Deploying through an unrelated helper would instead give that helper the supply, so use the intended launch factory. Tests demonstrate this distinction without requiring any production address or key.

For the launch specified in the assignment, allocation and pool configuration are the external launch system's responsibility. Its supplied terms are a native ETH pair, pool fee `12500` (1.25%), tick spacing `60`, initial-price provenance `79228162514264337593543950336`, and opening market cap `10000000000000000000` wei (10 ETH). The launch system derives the actual opening price from market cap, supply and token ordering. The factory distributes 10% to the launch's MerkleDistributor, uses 80% for the pool allocation, and forwards the remaining 10% to `0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d`. These supplied economics are not constructor settings or transfer taxes. The token does not perform these allocations itself.

The later manifest step owns `launch.json`; it is intentionally absent here. This repository contains buildable deployment bytecode sources, not a deployment transaction or a live token address.

## After launch

No owner settings or maintenance transactions are required. The launch operator is responsible for the manifest, factory deployment, distribution, pool setup, and verification of the published source and compiler settings. Verify the token address, metadata and total supply before integrating it. The deployer's initial full balance exists before factory allocation; after allocation, validate the resulting distribution and launch events instead of expecting the factory still to hold the supply.

Holders control transfers and approvals. `approve` replaces the allowance; `transferFrom` decrements finite allowances and leaves `type(uint256).max` allowances unchanged. To change an existing allowance safely with respect to transaction ordering, revoke it to zero and confirm that transaction before setting the new amount; a spender can still use an old approval before revocation confirms. Prefer limited allowances for the intended operation. Explicit `approve` calls emit `Approval`; the inherited OpenZeppelin implementation does not emit `Approval` when `transferFrom` spends allowance.

Transfers to the zero address revert, including zero-value transfers. Zero-value transfers between valid accounts succeed. An approved spender cannot exceed the holder's balance. Tokens sent to contracts that cannot return them, including the token contract itself, cannot be recovered by an administrator. The token has no payable entry point or rescue function.

Local verification consists of Foundry build, unit/fuzz/invariant tests, and formatting checks. These tests do not constitute an independent security audit or verification of the live launch infrastructure. Independent review and post-deployment verification remain responsibilities of the launch process; no transactions are broadcast by this project.
