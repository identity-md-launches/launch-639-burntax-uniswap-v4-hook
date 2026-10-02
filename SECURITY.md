# Local security review

This is the implementation author's review against the provided Ethereum and v4 security references, not an independent audit.

| Area | Result / boundary |
| --- | --- |
| Authorization | All three hook callbacks and `unlockCallback` require the immutable PoolManager; `unlockCallback` is reachable only through the hook's own `burnPending` unlock. `beforeInitialize` refuses the dynamic-fee flag and fees outside 500/3000/10000. Permission bits are validated in the constructor. Disabled selectors have no implementation or fallback. |
| Delta accounting | The only hook credit is BTAX tax. A matching manager `take` sends it to DEAD, or a matching `mint` holds it as a hook ERC-6909 claim when the manager's BTAX balance cannot fund the transfer yet. Redemption pairs `burn` with `take` to DEAD. Both return-delta permissions are required to cover specified and unspecified BTAX. Integration/fuzz/stateful tests check closed debts and balance conservation including claims. |
| NoOp exposure | No arbitrary or hookData-controlled deltas; exact-input specified tax is floor(input / 100), strictly less than positive input. No custom execution or router allowlist. |
| Partial execution | Unspecified tax uses actual pool execution. A nonzero specified tax requires a full adjusted BTAX fill; otherwise everything reverts. |
| Arithmetic | All amounts are minor units. No price oracle or decimal conversion. Division rounds down; inverse gross-up chooses the smallest exact solution. Cast limits are explicit. |
| External calls | The hook interacts only with the immutable manager (`take`, `mint`, `burn`, `balanceOf`, `unlock`) and reads the immutable standard ERC-20's balance. It has no storage of its own; the claim balance lives in the manager. `burnPending` inside another unlock reverts (`AlreadyUnlocked`). A malicious/reentrant token or manager is outside the deployment assumptions. |
| Settlement liquidity | An immediate burn needs BTAX already in the manager, which every buy has. A sell whose tax exceeds the manager's BTAX balance defers the tax as a claim instead of reverting; the next covered swap or any `burnPending()` call moves it to DEAD. Tested on a fresh manager, on a bought-out launch pool and with prepayment. No native currency is ever sent to DEAD. |
| Governance/custody | No administrator, upgrade, selfdestruct, delegatecall, rate change, or fund withdrawal. Runtime opcode scans cover hook and token. Accidental hook transfers stay stuck. |
| Slippage | Manager price limits are honored; router final minimum-output/maximum-input checks remain required. No MEV mitigation or oracle-based pricing is claimed. |
| Token | Constructor-only mint; ordinary ERC-20 transfer/allowance behavior; fixed 10^27 supply. DEAD transfers do not reduce totalSupply. |
| Deployment | Supplied authentic manager and already-deployed token, CREATE2 flags 0x20cc, atomic hook deployment and initialization. Offline salt utility is tested directly. |

Local checks comprise compilation, real-manager integration tests, fuzz tests and stateful invariants. They use fresh isolated state and no environment reads. The vendored inputs are pinned and their license notices retained.

Before production, a separate contributor should adversarially review the chosen gross-tax convention, specified partial-fill rejection, signed deltas and reserve/prepayment assumptions. The deployer is responsible for chain/factory/manager verification, target-router and quote integration, a chain-specific rehearsal, initial price/liquidity/distribution selection, source verification and monitoring. No fork rehearsal, external audit, formal verification, Slither/Mythril run or network deployment is represented as completed by this local assignment.
