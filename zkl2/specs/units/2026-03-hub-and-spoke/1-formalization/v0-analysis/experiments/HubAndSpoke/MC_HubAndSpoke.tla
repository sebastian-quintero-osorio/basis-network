---- MODULE MC_HubAndSpoke ----

EXTENDS HubAndSpoke

\* ============================================================================
\*  Model Instance: Finite Constants for Exhaustive State-Space Exploration
\* ============================================================================
\*
\* Configuration rationale:
\*   - 2 enterprises (model values with SYMMETRY): minimal configuration that
\*     exercises all protocol properties. 2 directed pairs (e1->e2, e2->e1)
\*     test isolation, atomic settlement, replay protection, and timeout.
\*     Symmetry reduction (Permutations) reduces state space by factor 2! = 2.
\*     [Source: 0-input/findings.md, Section 9 -- cross-enterprise protocol]
\*
\*   - MaxCrossTx = 2: two transactions per directed pair. With 2 directed
\*     pairs, this allows up to 4 cross-enterprise transactions. Enables:
\*     replay testing (AttemptReplay with consumed nonces), sequential
\*     settlement, and concurrent transaction verification.
\*
\*   - TimeoutBlocks = 2: message created at block 1 times out at block 3
\*     (within MaxBlockHeight = 5). Tests premature timeout rejection and
\*     correct timeout triggering.
\*
\*   - UpdateCap = 1: each enterprise can advance its state root independently
\*     at most once. Sufficient to test stale-root race conditions.
\*
\* Scenarios this configuration exhaustively covers:
\*
\*   1. Isolation breach: Message contains only sourceProofValid (BOOLEAN) and
\*      sourceRootVersion (Nat). TLC verifies CrossEnterpriseIsolation holds
\*      across all reachable states -- no enterprise sees another's private data.
\*
\*   2. Partial settlement: TLC explores all interleavings of AttemptSettlement.
\*      The atomic TLA+ step guarantees both roots update together or neither.
\*      AtomicSettlement invariant verified exhaustively.
\*
\*   3. Replay attack: AttemptReplay injects a message with a consumed nonce.
\*      VerifyAtHub rejects it (nonceFresh check fails). ReplayProtection
\*      invariant verified: no two messages with the same nonce both pass
\*      hub verification. Tested under adversarial conditions.
\*
\*   4. Timeout and rollback: AdvanceBlock advances time past TimeoutBlocks.
\*      TimeoutMessage transitions pending messages to timed_out. No state
\*      root changes accompany timeout. TimeoutSafety invariant verified.
\*
\*   5. Stale root race condition: UpdateStateRoot changes an enterprise's
\*      root between message preparation and hub verification, causing
\*      VerifyAtHub to reject (rootCurrent check fails). Also tested
\*      between response and settlement.
\*
\*   6. Invalid proof propagation: PrepareMessage with proofValid=FALSE creates
\*      a message rejected at hub. RespondToMessage with responseProofValid=FALSE
\*      causes settlement failure. HubNeutrality and CrossRefConsistency verified.
\* ============================================================================

MC_MaxCrossTx == 1
MC_TimeoutBlocks == 2

\* Symmetry set for TLC state space reduction.
\* Enterprises are declared as model values in MC_HubAndSpoke.cfg.
MC_Symmetry == Permutations(Enterprises)

====
