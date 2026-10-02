# BurnTax (BTAX)

BurnTax is a fixed-supply ERC-20 and an immutable Uniswap v4 hook. For every successful swap in a pool using this hook and containing its configured BTAX token, the hook transfers **1% of gross BTAX, rounded down to whole minor units**, to `0x000000000000000000000000000000000000dEaD`. The trader's PoolManager return delta includes the tax. The other currency is never taxed.

`BurnTaxToken` has name `BurnTax`, symbol `BTAX`, 18 decimals, and exactly **1,000,000,000 tokens (10^27 minor units)**, all minted to its constructor's caller. It has no constructor arguments and no subsequent mint path. Ordinary transfers and approvals are standard ERC-20 operations without a tax. Sending tokens to the dead address removes them from practical circulation; **ERC-20 `totalSupply()` stays constant**. There is no token-level burn function.

Neither the hook nor token has an owner, admin, pause, upgrade, withdrawal, recipient setter or tax setter. Manager and token addresses are constructor immutables. Accidental transfers to the hook cannot be recovered.

## Exact rule and rounding

On a **buy**, gross BTAX is the pool's BTAX output before the tax; the trader receives gross minus tax. On a **sell**, gross BTAX is the trader's total BTAX payment including the tax; the pool receives gross minus tax. The pool's own LP fee remains part of its ordinary swap accounting and is separate from this tax.

Let `tax(G) = floor(G / 100)` and `gross(N) = N + floor((N - 1) / 99)` for positive `N`, with `gross(0) = 0`. `gross(N)` is the *smallest* integer gross amount whose net after tax is exactly `N`. All amounts below are minor units, not rounded UI token amounts.

| Trade | How BTAX is accounted for |
| --- | --- |
| Exact-input buy | Execute the requested paired-currency input; burn `tax(pool BTAX output)` and deliver the remainder. |
| Exact-output buy | The requested BTAX output is **net to the trader**. Request `gross(requested output)` from the pool and burn the difference. |
| Exact-input sell | The specified BTAX input is the **total trader payment**. Burn `tax(requested input)` and swap the remainder through the pool. |
| Exact-output sell | Execute the requested paired-currency output. Charge `gross(pool BTAX input)` to the trader and burn the difference. |

For example, selling an exact 100 BTAX sends 1 BTAX to DEAD and 99 BTAX into the AMM. Buying an exact net 99 BTAX requires gross `99.999999999999999999` BTAX at 18-decimal precision, of which `0.999999999999999999` BTAX goes to DEAD. The smallest-gross convention avoids overcharging one minor unit at rounding boundaries. A gross leg below 100 minor units burns zero; splitting trades can exploit this rounding at dust scale.

`Burned(bytes32 indexed poolId, bool indexed isBuy, uint256 amount)` reports the full v4 pool ID, trader-facing direction (`true` = buy BTAX, `false` = sell BTAX), and the actual amount sent to DEAD. It emits once per successful BTAX-pool swap, including zero-tax dust swaps. Direction works with BTAX as either currency0 or currency1. It deliberately makes no end-user identity claim: the callback's `sender` is generally a router.

## Limits and integration responsibilities

- The rule covers every pool containing the configured BTAX **that selects this hook**, including multiple pairs/fees. Pools without BTAX receive zero hook deltas and emit no burn event. Pools selecting a different hook, unhooked pools, direct ERC-20 transfers, liquidity changes and donations are outside the tax.
- v4's `afterSwap` return delta can change only the **unspecified** currency. Consequently, a taxed exact-input sell or exact-output buy must fill its adjusted BTAX amount completely. If a price limit or exhausted liquidity causes a partial fill, the entire transaction reverts with `PartialFillWithSpecifiedTax` (wrapped by v4). No tokens burn and pool state rolls back. Exact-input buys and exact-output sells tax their actual execution and can partially fill. Zero-tax specified trades can also partially fill. Routers must decide whether a partial paired-currency exact output is acceptable and enforce their normal output checks.
- Burns are immediate ERC-20 transfers from the PoolManager in `afterSwap`, before an ordinary router settles input. The manager must already hold enough BTAX for the burn. A token-only seeded launch pool supports buys even when the manager has **zero native ETH**; no native currency is sent to DEAD. For a sell into a fresh pool seeded only with the other currency, an ordinary post-settlement router reverts if the manager has no BTAX. An integrating router can `sync -> transferFrom -> settle` its BTAX payment before calling `swap`, then settle/take its remaining net deltas. The tests demonstrate both the failure and successful prepayment. There are no deferred claims, redemption methods or withdrawal powers.
- Use the shipped standard token at the configured token address. Rebasing tokens, transfer-tax tokens, ERC-777-style callbacks and mutable/hostile replacement token implementations are not supported. Constructor code checks do not certify the identity of the token or manager; the deployer must verify both.
- Routers/quoters must understand both return-delta permissions, net exact-output buys, and the partial-fill limit. Apply minimum output / maximum input and deadlines against **final trader deltas**, including the tax. The hook has no oracle, price promise, sandwich protection, router allowlist or hookData-based exceptions. `hookData` cannot change the rate or direction.
- The token supply is fixed, but the underlying PoolManager's own protocol-fee governance and normal LP economics remain those of Uniswap. This hook neither controls them nor overrides the pool's LP fee. The dead address is the conventional irrecoverable recipient; no private key to it is assumed to be available.

## Contracts and permissions

- [`src/BurnTaxToken.sol`](src/BurnTaxToken.sol): OpenZeppelin ERC-20 with a constructor-only mint.
- [`src/BurnTaxHook.sol`](src/BurnTaxHook.sol): three callback selectors, each restricted to its immutable manager. `beforeInitialize` permits manager-valid initialization and requires a deployed hook response. `beforeSwap` returns a positive specified delta only when BTAX is specified. `afterSwap` takes the tax and returns a positive unspecified delta only when BTAX is unspecified.
- [`src/HookFlags.sol`](src/HookFlags.sol): address-flag constants and matching helpers.
- [`script/MineBurnTax.s.sol`](script/MineBurnTax.s.sol): bounded, deterministic CREATE2 salt search. This is an offline utility; it does not broadcast or read the environment.

Required address bits are **`0x20cc` (8396)** under the 14-bit `0x3fff` mask: `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. All other permissions are false, and the constructor validates the deployed address against those flags. The implementation directly uses v4-core interfaces rather than adding unused BaseHook callback stubs. No shared callback state, transient hook storage, shares, access-control role or dynamic fee utility is needed.

Positive hook deltas debit the trader in BTAX. `poolManager.take(BTAX, DEAD, fee)` gives the hook an equal negative delta, which cancels its positive return delta. The hook and router must finish each manager unlock with zero currency debt. The specified tax is bounded well below the requested amount on exact input, so it cannot consume the entire input or skip the AMM as a NoOp swap. Integer conversions are bounded before signed casts; v4 also checks final int128 delta arithmetic.

## Deployment parameters

Use a Cancun-compatible EVM and the pinned Solidity build configuration. Deploy the token first, then deploy the hook with:

```solidity
new BurnTaxHook(IPoolManager(chainPoolManager), address(deployedBurnTaxToken));
```

That expression illustrates the constructor arguments; actual deployment **requires a mined CREATE2 salt**, not ordinary CREATE. Both addresses must already have code. No manager address is hardcoded or inferred from the caller. In launch tooling the constructor inputs are `"$poolManager"` and `"$token"`, in that order. The token has no arguments. This assignment does not provide a launch manifest or send any transactions.

1. Choose the chain's authentic PoolManager and the actual CREATE2 deployer/factory. Deploy the token and confirm its entire `10^27` supply belongs to that deployer/factory. Determine its address before mining the hook.
2. Call the offline utility `MineBurnTax.run(manager, token, create2Deployer, start, attempts)`, for example with `start = 0`, `attempts = 200000`. It returns `(salt, predicted)`. If it reports `SaltNotFound`, search the next range. Parameters are function arguments; no environment variables, FFI or filesystem permissions are needed.
3. The CREATE2 preimage is `0xff || create2Deployer || salt || keccak256(type(BurnTaxHook).creationCode || abi.encode(manager, token))`. Deploy those **exact** bytes with that salt from that factory. Compiler settings, source, constructor arguments and factory address all affect the resulting address. Verify `(uint160(hook) & 0x3fff) == 0x20cc` and its reported permissions.
4. Sort the two pool currencies by address. For the default launch choose LP fee **3000 (0.3%)**, tick spacing **60**; 500 and 10000 are also accepted by this hook. Choose the paired currency, initial `sqrtPriceX96`, liquidity range, seed amounts and supply distribution explicitly. No launch price or distribution has been assumed in the contracts.
5. The launch factory should deploy the mined hook and initialize its intended pool in one transaction, then seed it according to the launch plan. Its initialization callback prevents initialization while the predicted hook has no code; once code exists, pool initialization is permissionless, so deployment and initialization should be atomic to avoid a race.
6. Verify source/constructor parameters and reproduce tests for the target manager/router. Confirm quotes, final slippage checks, initial BTAX reserves or router prepayment, and monitor `Burned` alongside token `Transfer` events. There is no operator maintenance call or recovery authority.

The tests mine and CREATE2-deploy the actual production hook bytecode; they do not bypass its address validation or relocate the PoolManager. Fixed-address mocks are used only for the paired ERC-20s to exercise both currency orderings.

## Build and checks

All required Solidity sources are vendored as ordinary files. There are no submodules or network dependency resolutions. With Foundry and **solc 0.8.26** installed:

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins solc 0.8.26, Cancun, the IR optimizer, no CBOR metadata, and no FFI or filesystem permissions. Tests use no environment variables, fork RPC, funded wallet or implicit script sender. They run against locally deployed, real v4 PoolManagers.

The suite covers all four modes in both currency orderings, matched untaxed AMM execution and LP fee growth, wallet/dead balances, pool/direction/amount events, unrelated pools, rounding boundaries, token behavior, initialization/address mining, missing constructor contracts, callback authorization, large amount bounds, specified and unspecified partial fills, settlement/slippage rollback, one-sided native pools, input prepayment and liquidity removal. Fuzz and stateful invariant tests check tax accounting, conservation, fixed supply, zero hook custody and manager settlement across swap sequences.

See [`DEPENDENCIES.md`](DEPENDENCIES.md) for pinned sources and licenses and [`SECURITY.md`](SECURITY.md) for the local review and remaining production review responsibilities. Passing tests are not an independent security audit.
