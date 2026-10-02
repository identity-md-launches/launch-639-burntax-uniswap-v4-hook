# Vendored dependencies

All dependencies are ordinary source files. No git submodules, package-manager caches or network access are required for compilation. Source files are unmodified subsets of these commits; upstream licenses and SPDX notices are retained.

| Directory | Upstream revision | Included subset |
| --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | Core source, PoolSwapTest/PoolModifyLiquidityTest/PoolTestBase and CurrencySettler test utilities, licenses |
| `lib/forge-std` | [foundry-rs/forge-std `77041d2ce690e692d6e03cc812b57d1ddaa4d505`](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505), v1.9.7 | `src/`, MIT/Apache licenses |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts `69c8def5f222ff96f2b5beff05dfba996368aa79`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79), v5.1.0 | ERC20 and its transitive interfaces/Context, MIT license |
| `lib/solmate` | [transmissions11/solmate `4b47a19038b798b4a33d9749d25e570443520647`](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | Owned.sol (PoolManager dependency), AGPL-3.0 license; revision matches v4-core's pinned submodule |

v4-core files use their individual upstream licenses, including BUSL-1.1 for PoolManager and some core libraries, MIT for interfaces and other files, and UNLICENSED for some test helpers. The hook/token project's MIT license does not relicense those files. The PoolManager and upstream test routers are used for local verification, not deployed by the delivered application contracts.
