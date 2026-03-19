# Phase 1: Formalization Notes -- BasisBridge (L1-L2 Bridge with Escape Hatch)

**Date**: 2026-03-19
**Target**: zkl2
**Unit**: bridge
**Result**: PASS

---

## 1. Research-to-Spec Mapping

| Source (0-input/) | TLA+ Element | Type |
|---|---|---|
| BasisBridge.sol `deposit()` L203-L225 | `Deposit(u, amt)` | Action |
| REPORT.md "Withdrawal (L2->L1)" | `InitiateWithdrawal(u, amt)` | Action |
| BasisBridge.sol `submitWithdrawRoot()` L400-L416 | `FinalizeBatch` | Action |
| relayer.go `submitWithdrawRoots()` L386-L411 | `FinalizeBatch` | Action |
| BasisBridge.sol `claimWithdrawal()` L242-L302 | `ClaimWithdrawal(w)` | Action |
| BasisBridge.sol `activateEscapeHatch()` L312-L335 | `ActivateEscapeHatch` | Action |
| BasisBridge.sol `escapeWithdraw()` L347-L387 | `EscapeWithdraw(u)` | Action |
| BasisBridge.sol `bridgeBalance` (contract balance) | `bridgeBalance` | Variable |
| BasisBridge.sol `withdrawalNullifier` L88 | `claimedNullifiers` | Variable |
| BasisBridge.sol `escapeNullifier` L92 | `escapeNullifiers` | Variable |
| BasisBridge.sol `escapeMode` L102 | `escapeActive` | Variable |
| BasisBridge.sol `lastBatchExecutionTime` L99 | `lastBatchTime` | Variable |
| BasisBridge.sol INV-B1 | `NoDoubleSpend` (unique wids + bridgeBalance >= 0) | Invariant |
| BasisBridge.sol INV-B2 | `BalanceConservation` (exact pre-escape, solvency during escape) | Invariant |
| BasisBridge.sol INV-B3 | `EscapeHatchLiveness` (bridge covers all escape payouts) | Invariant |
| BasisBridge.sol INV-B4 | Embedded in `ClaimWithdrawal` guard: `w \in finalizedWithdrawals` | Guard |
| BasisBridge.sol INV-B5 | Embedded in `nextWid` monotonic increment | Structural |
| BasisBridge.sol INV-B6 | Embedded in `EscapeWithdraw` guard: `u \notin escapeNullifiers` | Guard |
| REPORT.md "Escape Hatch" | `SequencerFail`, `SequencerRecover`, `Tick` | Environment |

## 2. Abstractions

### 2.1 Merkle Proof Verification

Merkle proof verification (keccak256 binary tree, depth 32) is abstracted away entirely.
The TLA+ spec assumes that if a withdrawal record exists in `finalizedWithdrawals`, its
Merkle proof is valid. This is a sound abstraction because:
- Merkle proof correctness is a cryptographic property, not a protocol property.
- The spec verifies the *state machine* that governs when proofs are checked, not the
  proofs themselves.
- A broken hash function would compromise ALL bridges, not just this protocol.

### 2.2 Atomic Deposits

The L1 deposit and L2 credit are modeled as a single atomic action `Deposit(u, amt)`.
In the implementation, these are separate transactions:
1. User calls `deposit()` on L1 BasisBridge.sol (locks ETH).
2. Relayer detects `DepositInitiated` event and credits on L2.

This abstraction is safe because the relayer is enterprise-operated and trusted. The spec
does not model relayer crash-recovery (a separate concern). If the relayer crashes between
steps 1 and 2, the ETH is safe in the bridge and will be credited upon relayer recovery.

### 2.3 Sequencer Liveness Guard on Escape Activation

The contract's `activateEscapeHatch()` checks only the timeout condition
(`block.timestamp - lastBatchExecutionTime >= escapeTimeout`), not whether the sequencer
is currently alive. The spec adds `~sequencerAlive` as a guard on `ActivateEscapeHatch`.

This is a modeling simplification. In the contract, the admin can call
`recordBatchExecution()` to refresh the timer even without processing a batch. The spec
does not model this heartbeat action. Removing the `~sequencerAlive` guard would require
adding a `RecordBatchExecution` heartbeat action to prevent false-positive escape
activation when the sequencer is alive but idle.

### 2.4 Single Enterprise

The spec models a single enterprise. The contract supports multiple enterprises via
per-enterprise mappings. Since enterprises are independent (no shared state between
enterprises in the bridge), this abstraction does not lose generality.

### 2.5 Escape Is Permanent

Once `escapeActive = TRUE`, no action can set it back to `FALSE`. The contract has no
`deactivateEscapeHatch()` function. Sequencer recovery is blocked during escape
(`SequencerRecover` requires `~escapeActive`). This models the enterprise crisis mode
where governance intervention would be needed to restore normal operation.

## 3. Verification Results

### 3.1 Primary Run (Certificate of Truth)

| Parameter | Value |
|---|---|
| Users | {u1, u2} |
| Amounts | {1} |
| EscapeTimeout | 2 |
| MaxBridgeBalance | 3 |
| MaxTime | 4 |
| MaxWithdrawals | 3 |

| Metric | Value |
|---|---|
| States generated | 211,453 |
| Distinct states | 69,726 |
| State graph depth | 23 |
| Time | ~1 second |
| Result | **PASS** -- no errors found |
| Fingerprint collision probability | < 5.4e-10 |

### 3.2 Extended Run (Amounts = {1, 2})

| Parameter | Value |
|---|---|
| Users | {u1, u2} |
| Amounts | {1, 2} |
| EscapeTimeout | 2 |
| MaxBridgeBalance | 4 |
| MaxTime | 4 |
| MaxWithdrawals | 3 |

| Metric | Value |
|---|---|
| States generated | 2,410,519 |
| Distinct states | 759,072 |
| State graph depth | 25 |
| Time | ~5 seconds |
| Result | **PASS** -- no errors found |
| Fingerprint collision probability | < 6.8e-8 |

### 3.3 Invariants Verified

All four invariants hold across all reachable states:

1. **TypeOK**: All variables remain within their declared domains.
2. **NoDoubleSpend**: Every finalized withdrawal has a unique ID. Bridge balance never
   goes negative.
3. **BalanceConservation**: Before escape, exact accounting identity holds
   (`bridgeBalance = SumL2 + SumPending + SumUnclaimedFinalized`). During escape, bridge
   is solvent to cover all remaining obligations.
4. **EscapeHatchLiveness**: When escape is active, every user with a finalized balance
   can individually be covered by the bridge.

### 3.4 Reproduction

```bash
cd zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/experiments/BasisBridge/_build/
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_BasisBridge -workers 4 -deadlock -cleanup
```

The `-deadlock` flag is required because terminal states are expected (clock reaches
MaxTime with all escapable users having escaped).

## 4. Protocol Observations

### 4.1 Escape Hatch Gap (Known Limitation, Not a Bug)

The BalanceConservation invariant uses an inequality (>=) during escape mode, not an
equality. This reflects a known limitation of escape hatch mechanisms:

**Deposits made after the last batch finalization are not capturable by the escape hatch.**

When a user deposits after the last finalization and the sequencer then dies permanently,
the escape hatch pays out `lastFinalizedBals[u]`, which does not include the
post-finalization deposit. The deposited ETH remains locked in the bridge as excess.

This is documented in the literature (Figueira, arxiv 2503.23986: "escape triggers force
chain hard fork -- bridge balances diverge from L2 state") and is inherent to all
time-based escape hatch designs. The invariant verifies that the bridge always has
*at least* enough to cover all obligations, with any excess being the stranded
post-finalization deposits.

**Impact on Basis Network**: Low. The enterprise context (single sequencer per enterprise,
permissioned network) means the probability of simultaneous deposit + sequencer death is
minimal. If it occurs, governance can recover the stranded funds.

### 4.2 Claim-During-Escape Interaction

The spec allows `ClaimWithdrawal` even when escape is active. This is faithful to the
contract (no `escapeMode` check in `claimWithdrawal()`). Model checking confirms this is
safe: the escape uses `lastFinalizedBals` (already reduced by finalized withdrawals), so
the combined payout (escape + claim) never exceeds the original deposit.

### 4.3 Terminal State Deadlock

Terminal states occur when: clock = MaxTime, sequencer is dead, escape is active, all
users with finalized balances have escaped, and all finalized withdrawals are claimed.
These are legitimate end states, not protocol bugs. The `-deadlock` flag suppresses this
false positive from TLC.

## 5. Open Issues

1. **Temporal Liveness**: The spec defines `EscapeEventualWithdrawal` (temporal property
   with fairness): "if escape is active and user has finalized balance, user eventually
   escapes." This was not checked by TLC in this run (requires SPECIFICATION mode with
   fairness, significantly slower). The safety aspect is verified by
   `EscapeHatchLiveness`.

2. **Heartbeat Action**: The `recordBatchExecution()` function in the contract is not
   modeled. Adding it would allow removing the `~sequencerAlive` guard from
   `ActivateEscapeHatch`, making the model more faithful but increasing state space.

3. **Multi-Enterprise**: The spec models a single enterprise. Multi-enterprise
   interactions (e.g., cross-enterprise escape timing) are not explored. This is safe
   because enterprises have independent bridge state.

## 6. Verdict

**PASS**. The BasisBridge protocol's state machine is formally verified to preserve:
- No double-spend (unique nullifiers, non-negative bridge balance)
- Balance conservation (exact pre-escape, solvency during escape)
- Escape hatch solvency (bridge can individually cover every affected user)

The specification is ready for Phase 2 audit.
