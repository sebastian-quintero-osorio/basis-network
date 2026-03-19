---- MODULE MC_BasisBridge ----
(*
 * Model Checking Instance for BasisBridge specification.
 *
 * Finite constants chosen to expose concurrency and safety bugs
 * while keeping state space tractable for exhaustive search:
 *   - 2 users: minimum to test cross-user interactions and escape races
 *   - Amounts {1}: unit amounts to bound withdrawal record proliferation
 *   - EscapeTimeout = 2: allows escape activation within MaxTime window
 *   - MaxBridgeBalance = 3: allows 3 deposits, sufficient for multi-user scenarios
 *   - MaxTime = 4: EscapeTimeout + 2 for post-escape exploration
 *   - MaxWithdrawals = 3: bounds total withdrawal ops to prevent wid explosion
 *)

EXTENDS BasisBridge

====
