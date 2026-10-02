# Local security review

This is the implementation author's review against the provided Ethereum and v4 security references, not an independent audit.

| Area | Result / boundary |
| --- | --- |
| Authorization | All three implemented callbacks require the immutable PoolManager. Permission bits are validated in the constructor. Disabled selectors have no implementation or fallback. |
| Delta accounting | The only hook credit is BTAX tax. A matching manager `take` sends it to DEAD. Both return-delta permissions are required to cover specified and unspecified BTAX. Integration/fuzz/stateful tests check closed debts and balance conservation. |
| NoOp exposure | No arbitrary or hookData-controlled deltas; exact-input specified tax is floor(input / 100), strictly less than positive input. No custom execution or router allowlist. |
| Partial execution | Unspecified tax uses actual pool execution. A nonzero specified tax requires a full adjusted BTAX fill; otherwise everything reverts. |
| Arithmetic | All amounts are minor units. No price oracle or decimal conversion. Division rounds down; inverse gross-up chooses the smallest exact solution. Cast limits are explicit. |
| External calls | The only hook interaction is `take` on the immutable manager, which transfers the immutable standard ERC-20. The hook has no mutable accounting or callback-to-callback state to corrupt. A malicious/reentrant token or manager is outside the deployment assumptions. |
| Settlement liquidity | Immediate burn needs BTAX already in the manager. Token-only fresh native pools work. Empty BTAX reserves require router input prepayment; failure and recovery by prepayment are tested. No ETH recipient interaction or claim redemption. |
| Governance/custody | No administrator, upgrade, selfdestruct, delegatecall, rate change, or fund withdrawal. Runtime opcode scans cover hook and token. Accidental hook transfers stay stuck. |
| Slippage | Manager price limits are honored; router final minimum-output/maximum-input checks remain required. No MEV mitigation or oracle-based pricing is claimed. |
| Token | Constructor-only mint; ordinary ERC-20 transfer/allowance behavior; fixed 10^27 supply. DEAD transfers do not reduce totalSupply. |
| Deployment | Supplied authentic manager and already-deployed token, CREATE2 flags 0x20cc, atomic hook deployment and initialization. Offline salt utility is tested directly. |

Local checks comprise compilation, real-manager integration tests, fuzz tests and stateful invariants. They use fresh isolated state and no environment reads. The vendored inputs are pinned and their license notices retained.

Before production, a separate contributor should adversarially review the chosen gross-tax convention, specified partial-fill rejection, signed deltas and reserve/prepayment assumptions. The deployer is responsible for chain/factory/manager verification, target-router and quote integration, a chain-specific rehearsal, initial price/liquidity/distribution selection, source verification and monitoring. No fork rehearsal, external audit, formal verification, Slither/Mythril run or network deployment is represented as completed by this local assignment.
