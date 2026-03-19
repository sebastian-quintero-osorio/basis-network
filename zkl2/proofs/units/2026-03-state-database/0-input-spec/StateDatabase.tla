---- MODULE StateDatabase ----
(* =================================================================== *)
(* EVM State Database -- Two-Level Sparse Merkle Tree Specification    *)
(* =================================================================== *)
(*                                                                     *)
(* Basis Network zkEVM L2 -- State Management Layer                    *)
(* Research Unit: RU-L4 (State Database -- SMT Poseidon for EVM)       *)
(*                                                                     *)
(* EXTENDS the SparseMerkleTree formalization from RU-V1 (validium)    *)
(* to model the EVM account model with two trie levels:                *)
(*   Level 1: Account Trie (address -> account hash)                   *)
(*   Level 2: Storage Tries (slot -> value, one per contract)          *)
(*                                                                     *)
(* [Source: 0-input/REPORT.md -- "EVM Account Model Mapping"]          *)
(* [Source: 0-input/hypothesis.json -- State Database hypothesis]      *)
(* [Reference: validium/specs/units/2026-03-sparse-merkle-tree/        *)
(*             1-formalization/v0-analysis/specs/SparseMerkleTree/      *)
(*             SparseMerkleTree.tla]                                    *)
(*                                                                     *)
(* FORMALIZED OPERATIONS:                                              *)
(*   CreateAccount(addr)           -- Activate a dormant account       *)
(*   Transfer(from, to, amount)    -- Move balance (UpdateBalance)     *)
(*   SetStorage(contract, slot, v) -- Write/clear contract storage     *)
(*   SelfDestruct(contract, benef) -- Destroy contract, send balance   *)
(*                                                                     *)
(* GetStorage is a read-only operation. Its correctness is verified    *)
(* by the StorageIsolation invariant: every storage slot has a valid   *)
(* Merkle proof against the contract's storage root.                   *)
(*                                                                     *)
(* VERIFIED INVARIANTS:                                                *)
(*   ConsistencyInvariant  -- Two-level trie roots match recomputation *)
(*   AccountIsolation      -- Each account has valid independent proof *)
(*   StorageIsolation      -- Each storage slot has valid indep. proof *)
(*   BalanceConservation   -- Total balance is preserved across all    *)
(*                            state transitions                        *)
(*                                                                     *)
(* HASH FUNCTION:                                                      *)
(*   Inherited from RU-V1 SparseMerkleTree.tla.                        *)
(*   Algebraic hash over F_65537 (Fermat prime F4).                    *)
(*   Production: Poseidon2 over BN254 scalar field (240 R1CS).         *)
(*   [Source: 0-input/REPORT.md, Section 2 -- Hash Performance]        *)
(* =================================================================== *)

EXTENDS Integers, FiniteSets, TLC

(* ======================================== *)
(*           CONSTANTS                      *)
(* ======================================== *)

CONSTANTS
    Addresses,      \* Set of address indices (leaf indices in account trie)
    Contracts,      \* Subset of Addresses: smart contract addresses
    Slots,          \* Set of storage slot indices (leaf indices in storage tries)
    MaxBalance,     \* Total supply = max individual balance (single EOA genesis)
    StorageValues,  \* Set of non-zero storage values (BN254 field elements)
    ACCOUNT_DEPTH,  \* Depth of the account trie
    STORAGE_DEPTH   \* Depth of each contract's storage trie

(* ======================================== *)
(*           DERIVED CONSTANTS              *)
(* ======================================== *)

\* Externally-owned accounts (non-contract addresses)
EOAs == Addresses \ Contracts

\* Sentinel value for empty (unoccupied) entries.
\* [Source: RU-V1 SparseMerkleTree.tla, line 57 -- "EMPTY == 0"]
EMPTY == 0

\* Power of 2 (TLA+ does not provide exponentiation)
RECURSIVE Pow2(_)
Pow2(n) == IF n = 0 THEN 1 ELSE 2 * Pow2(n - 1)

\* Complete leaf index sets for each trie level.
\* Used in isolation invariants to verify ALL positions (including empty).
AccountLeafIndices == 0..(Pow2(ACCOUNT_DEPTH) - 1)
StorageLeafIndices == 0..(Pow2(STORAGE_DEPTH) - 1)

(* ======================================== *)
(*           ASSUMPTIONS                    *)
(* ======================================== *)

ASSUME ACCOUNT_DEPTH \in (Nat \ {0})
ASSUME STORAGE_DEPTH \in (Nat \ {0})
ASSUME Contracts \subseteq Addresses
ASSUME Contracts # {}
ASSUME EOAs # {}
ASSUME Addresses \subseteq AccountLeafIndices
ASSUME Slots \subseteq StorageLeafIndices
ASSUME Slots # {}
ASSUME EMPTY \notin StorageValues
ASSUME StorageValues # {}
ASSUME MaxBalance \in (Nat \ {0})

\* Single EOA genesis: one externally-owned account holds the entire
\* initial supply. This guarantees MaxBalance is both the total supply
\* and the upper bound for any individual balance (by conservation).
ASSUME Cardinality(EOAs) = 1

(* ======================================== *)
(*     HASH FUNCTION (from RU-V1)           *)
(* ======================================== *)
\*
\* Inherited from SparseMerkleTree.tla (RU-V1).
\* Algebraic hash over the Fermat prime F4 = 2^16 + 1 = 65537.
\*
\* Properties:
\*   P1. Hash(a, b) >= 1 for all a, b >= 0 (distinguishes from EMPTY).
\*   P2. Injective within the model's finite domain (no modular wrap).
\*
\* Production: Poseidon2 2-to-1 hash over BN254 scalar field.
\* [Source: 0-input/REPORT.md, Section 2.1 -- "Poseidon2 2-to-1 (fr.Element)
\*          4.46 us/hash, 224,000 hashes/s"]
\* [Source: RU-V1 SparseMerkleTree.tla, lines 82-110]

HASH_MOD == 65537

Hash(a, b) == ((a * 31 + b * 17 + 1) % HASH_MOD) + 1

\* Leaf hash: H(key, value) for occupied leaves, 0 for empty.
\* [Source: 0-input/code/smt.go -- Insert method, leaf hash computation]
\* [Source: RU-V1 SparseMerkleTree.tla, line 110]
LeafHash(key, value) == IF value = EMPTY THEN EMPTY ELSE Hash(key, value)

(* ======================================== *)
(*     DEFAULT HASHES (from RU-V1)          *)
(* ======================================== *)
\*
\* Precomputed hashes for all-empty subtrees at each level.
\* [Source: 0-input/code/smt.go -- defaultHashes precomputation loop]
\* [Source: RU-V1 SparseMerkleTree.tla, lines 124-128]

RECURSIVE DefaultHash(_)
DefaultHash(level) ==
    IF level = 0 THEN EMPTY
    ELSE LET prev == DefaultHash(level - 1)
         IN Hash(prev, prev)

(* ======================================== *)
(*     TREE COMPUTATION (from RU-V1)        *)
(* ======================================== *)
\*
\* Depth-parameterized tree computation operators.
\* Reused for both account trie (ACCOUNT_DEPTH) and storage tries
\* (STORAGE_DEPTH). The parameterization allows a single set of
\* operators to serve the two-level trie architecture.
\*
\* [Source: RU-V1 SparseMerkleTree.tla, lines 139-156]

\* Look up the value of a leaf by its index.
\* Keys not in the entries domain are always EMPTY.
EntryValue(e, idx) == IF idx \in DOMAIN(e) THEN e[idx] ELSE EMPTY

\* Recursively compute the hash of a tree node by full rebuild.
\* This is the reference truth used by ConsistencyInvariant.
\* [Source: 0-input/REPORT.md, Section 3.3 -- "O(depth) hashes per path"]
RECURSIVE ComputeNode(_, _, _)
ComputeNode(e, level, index) ==
    IF level = 0
    THEN LeafHash(index, EntryValue(e, index))
    ELSE LET leftChild  == ComputeNode(e, level - 1, 2 * index)
             rightChild == ComputeNode(e, level - 1, 2 * index + 1)
         IN Hash(leftChild, rightChild)

\* Compute root hash by full tree rebuild.
ComputeRoot(e, depth) == ComputeNode(e, depth, 0)

(* ======================================== *)
(*     PATH OPERATIONS (from RU-V1)         *)
(* ======================================== *)
\*
\* Navigation operators for the tree path from leaf to root.
\* [Source: RU-V1 SparseMerkleTree.tla, lines 160-182]
\* [Source: 0-input/code/smt.go -- getBit, sibling computation]

\* Extract the direction bit at a given level for a key.
\* 0 = left child, 1 = right child.
PathBit(key, level) == (key \div Pow2(level)) % 2

\* Compute the index of the sibling node at a given level.
SiblingIndex(key, level) ==
    LET ancestorIdx == key \div Pow2(level)
    IN IF ancestorIdx % 2 = 0
       THEN ancestorIdx + 1
       ELSE ancestorIdx - 1

\* Compute the hash of the sibling subtree at a given level.
SiblingHash(e, key, level) ==
    ComputeNode(e, level, SiblingIndex(key, level))

(* ======================================== *)
(*     INCREMENTAL PATH RECOMPUTATION       *)
(* ======================================== *)
\*
\* After modifying a single leaf, recompute only the path from that
\* leaf to the root using siblings from the old tree. This is the
\* O(depth) update algorithm. Depth-parameterized for two-level
\* trie support.
\*
\* [Source: 0-input/code/smt.go -- Insert method, path update loop]
\* [Source: 0-input/code/smt_optimized.go -- InsertUint64]
\* [Source: RU-V1 SparseMerkleTree.tla, lines 195-204]

RECURSIVE WalkUp(_, _, _, _, _)
WalkUp(oldEntries, currentHash, key, level, depth) ==
    IF level = depth
    THEN currentHash
    ELSE LET bit     == PathBit(key, level)
             sibling == SiblingHash(oldEntries, key, level)
             parent  == IF bit = 0
                        THEN Hash(currentHash, sibling)
                        ELSE Hash(sibling, currentHash)
         IN WalkUp(oldEntries, parent, key, level + 1, depth)

(* ======================================== *)
(*     PROOF OPERATIONS (from RU-V1)        *)
(* ======================================== *)
\*
\* Merkle proof generation and verification.
\* Depth-parameterized for two-level trie support.
\*
\* [Source: 0-input/code/smt.go -- GetProof, VerifyProof methods]
\* [Source: RU-V1 SparseMerkleTree.tla, lines 216-242]

\* Generate the sequence of sibling hashes for a Merkle proof.
ProofSiblings(e, key, depth) ==
    [level \in 0..(depth - 1) |-> SiblingHash(e, key, level)]

\* Generate the path bit sequence for a key.
PathBitsForKey(key, depth) ==
    [level \in 0..(depth - 1) |-> PathBit(key, level)]

\* Verify a Merkle proof by walking up from the leaf hash.
RECURSIVE VerifyWalkUp(_, _, _, _, _)
VerifyWalkUp(currentHash, siblings, pathBits, level, depth) ==
    IF level = depth
    THEN currentHash
    ELSE LET parent == IF pathBits[level] = 0
                       THEN Hash(currentHash, siblings[level])
                       ELSE Hash(siblings[level], currentHash)
         IN VerifyWalkUp(parent, siblings, pathBits, level + 1, depth)

\* Full proof verification: walk up and compare to expected root.
VerifyProof(expectedRoot, leafHash, siblings, pathBits, depth) ==
    VerifyWalkUp(leafHash, siblings, pathBits, 0, depth) = expectedRoot

(* ======================================== *)
(*     EVM ACCOUNT MODEL                    *)
(* ======================================== *)
\*
\* Two-level trie structure for EVM state:
\*
\*   Account Trie (Level 1):
\*     key   = address (leaf index in account trie)
\*     value = Hash(balance, storageRoot)
\*
\*   Storage Tries (Level 2, one per contract):
\*     key   = storage slot (leaf index in storage trie)
\*     value = storage value (BN254 field element)
\*
\* [Source: 0-input/REPORT.md, Section 3 -- "EVM Account Model Mapping"]
\* [Source: 0-input/REPORT.md -- "Account Trie (SMT, depth 160 or 256):
\*   key = address (20 bytes)
\*   value = Poseidon(nonce, balance, codeHash, storageRoot)"]
\*
\* Simplification: nonce and codeHash are omitted from the model.
\* They are orthogonal to the isolation and conservation properties
\* under verification. The two-level trie structure and the four
\* invariants are fully exercised without them.

(* ======================================== *)
(*           VARIABLES                      *)
(* ======================================== *)

VARIABLES
    balances,       \* [Addresses -> 0..MaxBalance] -- account balances
    storageData,    \* [Contracts -> [Slots -> StorageValues \cup {EMPTY}]]
    alive,          \* [Addresses -> BOOLEAN] -- account existence flag
    accountRoot,    \* Root hash of the account trie (maintained incrementally)
    storageRoots    \* [Contracts -> Nat] -- root hash per contract storage trie

vars == << balances, storageData, alive, accountRoot, storageRoots >>

(* ======================================== *)
(*     ACCOUNT AND STORAGE COMPUTATION      *)
(* ======================================== *)

\* Compute the "value" of an account for the account trie.
\* Dead accounts map to EMPTY (invisible in the trie).
\* Live accounts: Hash(balance, storageRoot).
\* EOAs use DefaultHash(STORAGE_DEPTH) as storageRoot (empty storage).
\*
\* [Source: 0-input/REPORT.md -- "value = Poseidon(nonce, balance,
\*          codeHash, storageRoot)"]
AccountValue(addr) ==
    IF ~alive[addr] THEN EMPTY
    ELSE LET sr == IF addr \in Contracts
                   THEN storageRoots[addr]
                   ELSE DefaultHash(STORAGE_DEPTH)
         IN Hash(balances[addr], sr)

\* Build the entries function for the account trie.
\* Maps each address to its account value.
AccountEntries == [addr \in Addresses |-> AccountValue(addr)]

\* Compute account root by full rebuild (reference truth).
ComputeAccountRoot == ComputeRoot(AccountEntries, ACCOUNT_DEPTH)

\* Compute storage root for a specific contract by full rebuild.
\* [Source: 0-input/code/smt.go -- Root() method]
ComputeStorageRoot(contract) ==
    ComputeRoot(storageData[contract], STORAGE_DEPTH)

(* ======================================== *)
(*     BALANCE AGGREGATION                  *)
(* ======================================== *)

\* Recursive summation over a finite set of addresses.
\* Addition is commutative, so CHOOSE order does not affect the result.
RECURSIVE SumOver(_, _)
SumOver(f, S) ==
    IF S = {} THEN 0
    ELSE LET x == CHOOSE x \in S : TRUE
         IN f[x] + SumOver(f, S \ {x})

\* Total balance across all accounts.
\* Dead accounts contribute 0 (their balance is always 0 by construction).
TotalBalance == SumOver(balances, Addresses)

(* ======================================== *)
(*           TYPE INVARIANT                 *)
(* ======================================== *)

TypeOK ==
    /\ balances \in [Addresses -> 0..MaxBalance]
    /\ storageData \in [Contracts -> [Slots -> StorageValues \cup {EMPTY}]]
    /\ alive \in [Addresses -> BOOLEAN]
    /\ accountRoot \in Nat
    /\ storageRoots \in [Contracts -> Nat]

(* ======================================== *)
(*           INITIAL STATE                  *)
(* ======================================== *)
\*
\* Genesis state: the single EOA holds the entire supply (MaxBalance).
\* All contracts start dead (not yet deployed), with empty storage.
\*
\* [Source: 0-input/REPORT.md -- genesis state for enterprise L2]

Init ==
    /\ balances = [addr \in Addresses |->
         IF addr \in EOAs THEN MaxBalance ELSE 0]
    /\ storageData = [c \in Contracts |-> [s \in Slots |-> EMPTY]]
    /\ alive = [addr \in Addresses |-> addr \in EOAs]
    /\ storageRoots = [c \in Contracts |-> DefaultHash(STORAGE_DEPTH)]
    /\ accountRoot = ComputeAccountRoot

(* ======================================== *)
(*           ACTIONS                        *)
(* ======================================== *)

\* ---- CreateAccount ------------------------------------------------
\* Activate a dormant (dead) address with zero balance.
\* Models contract deployment (CREATE/CREATE2 in EVM).
\* Single-step incremental account root update.
\*
\* [Source: 0-input/REPORT.md -- EVM account creation model]
\* [Source: 0-input/code/smt.go -- Insert for new account entry]
CreateAccount(addr) ==
    /\ ~alive[addr]
    /\ LET sr       == IF addr \in Contracts
                       THEN storageRoots[addr]
                       ELSE DefaultHash(STORAGE_DEPTH)
           newVal   == Hash(0, sr)
           newLeaf  == LeafHash(addr, newVal)
           newRoot  == WalkUp(AccountEntries, newLeaf, addr, 0,
                              ACCOUNT_DEPTH)
       IN /\ alive'        = [alive EXCEPT ![addr] = TRUE]
          /\ balances'     = [balances EXCEPT ![addr] = 0]
          /\ accountRoot'  = newRoot
          /\ UNCHANGED << storageData, storageRoots >>

\* ---- Transfer (UpdateBalance) ------------------------------------
\* Move balance from one alive account to another.
\* Two-step incremental account root update:
\*   Step 1: update sender leaf using current tree siblings.
\*   Step 2: update receiver leaf using intermediate tree siblings.
\*
\* [Source: 0-input/REPORT.md -- EVM balance transfer model]
\* [Source: 0-input/code/smt_optimized.go -- sequential batch updates]
Transfer(from, to, amount) ==
    /\ alive[from]
    /\ alive[to]
    /\ from # to
    /\ amount > 0
    /\ balances[from] >= amount
    /\ LET \* Step 1: update sender
           fromSR       == IF from \in Contracts
                           THEN storageRoots[from]
                           ELSE DefaultHash(STORAGE_DEPTH)
           newFromVal   == Hash(balances[from] - amount, fromSR)
           newFromLeaf  == LeafHash(from, newFromVal)
           interEntries == [AccountEntries EXCEPT ![from] = newFromVal]
           interRoot    == WalkUp(AccountEntries, newFromLeaf, from, 0,
                                  ACCOUNT_DEPTH)

           \* Step 2: update receiver using intermediate tree
           toSR         == IF to \in Contracts
                           THEN storageRoots[to]
                           ELSE DefaultHash(STORAGE_DEPTH)
           newToVal     == Hash(balances[to] + amount, toSR)
           newToLeaf    == LeafHash(to, newToVal)
           finalRoot    == WalkUp(interEntries, newToLeaf, to, 0,
                                  ACCOUNT_DEPTH)
       IN /\ balances'    = [balances EXCEPT ![from] = @ - amount,
                                             ![to]   = @ + amount]
          /\ accountRoot' = finalRoot
          /\ UNCHANGED << storageData, alive, storageRoots >>

\* ---- SetStorage ---------------------------------------------------
\* Write a value to a contract's storage slot, or clear it (EMPTY).
\* Two-level incremental update:
\*   Level 2: update storage trie -> new storageRoot.
\*   Level 1: update account trie (account hash changed).
\*
\* When value = EMPTY, this models storage deletion (SSTORE(key, 0)).
\*
\* [Source: 0-input/REPORT.md -- "Storage Trie (SMT per contract)"]
\* [Source: 0-input/code/smt.go -- Insert/Delete for storage entries]
SetStorage(contract, slot, value) ==
    /\ contract \in Contracts
    /\ alive[contract]
    /\ slot \in Slots
    /\ value \in StorageValues \cup {EMPTY}
    /\ value # storageData[contract][slot]
    /\ LET \* Level 2: update storage trie
           oldSE      == storageData[contract]
           newSLeaf   == LeafHash(slot, value)
           newSR      == WalkUp(oldSE, newSLeaf, slot, 0, STORAGE_DEPTH)

           \* Level 1: update account trie (storageRoot changed)
           newAccVal  == Hash(balances[contract], newSR)
           newAccLeaf == LeafHash(contract, newAccVal)
           newAR      == WalkUp(AccountEntries, newAccLeaf, contract, 0,
                                ACCOUNT_DEPTH)
       IN /\ storageData'  = [storageData EXCEPT ![contract][slot] = value]
          /\ storageRoots' = [storageRoots EXCEPT ![contract] = newSR]
          /\ accountRoot'  = newAR
          /\ UNCHANGED << balances, alive >>

\* ---- SelfDestruct -------------------------------------------------
\* Destroy a contract: transfer remaining balance to a beneficiary,
\* clear all storage, mark account as dead.
\* Two-step account trie update:
\*   Step 1: kill contract (leaf -> EMPTY).
\*   Step 2: credit beneficiary using intermediate tree.
\*
\* [Source: 0-input/REPORT.md -- EVM SELFDESTRUCT semantics]
SelfDestruct(contract, beneficiary) ==
    /\ contract \in Contracts
    /\ alive[contract]
    /\ beneficiary \in Addresses
    /\ beneficiary # contract
    /\ alive[beneficiary]
    /\ LET \* Step 1: kill the contract (leaf becomes EMPTY)
           deadLeaf     == LeafHash(contract, EMPTY)  \* = EMPTY
           interEntries == [AccountEntries EXCEPT ![contract] = EMPTY]
           interRoot    == WalkUp(AccountEntries, deadLeaf, contract, 0,
                                  ACCOUNT_DEPTH)

           \* Step 2: credit beneficiary with contract's balance
           benSR        == IF beneficiary \in Contracts
                           THEN storageRoots[beneficiary]
                           ELSE DefaultHash(STORAGE_DEPTH)
           newBenVal    == Hash(balances[beneficiary] + balances[contract],
                                benSR)
           newBenLeaf   == LeafHash(beneficiary, newBenVal)
           finalRoot    == WalkUp(interEntries, newBenLeaf, beneficiary, 0,
                                  ACCOUNT_DEPTH)
       IN /\ alive'        = [alive EXCEPT ![contract] = FALSE]
          /\ balances'     = [balances EXCEPT
                                ![contract]    = 0,
                                ![beneficiary] = @ + balances[contract]]
          /\ storageData'  = [storageData EXCEPT
                                ![contract] = [s \in Slots |-> EMPTY]]
          /\ storageRoots' = [storageRoots EXCEPT
                                ![contract] = DefaultHash(STORAGE_DEPTH)]
          /\ accountRoot'  = finalRoot

(* ======================================== *)
(*           NEXT-STATE RELATION            *)
(* ======================================== *)

Next ==
    \/ \E addr \in Addresses : CreateAccount(addr)
    \/ \E from, to \in Addresses, amt \in 1..MaxBalance :
         Transfer(from, to, amt)
    \/ \E c \in Contracts, s \in Slots, v \in StorageValues \cup {EMPTY} :
         SetStorage(c, s, v)
    \/ \E c \in Contracts, b \in Addresses :
         SelfDestruct(c, b)

(* ======================================== *)
(*           SPECIFICATION                  *)
(* ======================================== *)

Spec == Init /\ [][Next]_vars

(* ======================================== *)
(*           SAFETY PROPERTIES              *)
(* ======================================== *)

\* CONSISTENCY INVARIANT (extended from RU-V1)
\* [Why]: The two-level trie roots must be deterministic functions of
\* the current state. Incremental WalkUp updates must always agree
\* with full tree rebuilds (ComputeRoot). This is the foundational
\* invariant: if it fails, the state database is unsound and no
\* Merkle proof can be trusted.
\*
\* Verifies BOTH levels:
\*   (a) accountRoot = ComputeRoot(AccountEntries, ACCOUNT_DEPTH)
\*   (b) For each contract: storageRoot = ComputeRoot(storage, STORAGE_DEPTH)
\*
\* [Source: RU-V1 SparseMerkleTree.tla -- ConsistencyInvariant]
\* Extended for two-level trie with account + storage roots.
ConsistencyInvariant ==
    /\ accountRoot = ComputeAccountRoot
    /\ \A c \in Contracts : storageRoots[c] = ComputeStorageRoot(c)

\* ACCOUNT ISOLATION
\* [Why]: Operations on account A must not corrupt account B's state.
\* Verified by proof completeness: every leaf position in the account
\* trie (including permanently empty positions) has a valid Merkle proof
\* against the current root. If any action corrupted a non-target
\* account's data, the proof for that account would fail to verify.
\*
\* This extends CompletenessInvariant from RU-V1 to the account trie.
\* Quantifies over ALL leaf positions (not just active accounts) to
\* verify non-membership proofs for empty positions.
\*
\* [Source: 0-input/REPORT.md -- "AccountIntegrity: Operations on one
\*          account do not affect others"]
\* [Source: RU-V1 SparseMerkleTree.tla -- CompletenessInvariant]
AccountIsolation ==
    \A addr \in AccountLeafIndices :
        LET val      == EntryValue(AccountEntries, addr)
            leafH    == LeafHash(addr, val)
            siblings == ProofSiblings(AccountEntries, addr, ACCOUNT_DEPTH)
            pathBits == PathBitsForKey(addr, ACCOUNT_DEPTH)
        IN VerifyProof(accountRoot, leafH, siblings, pathBits,
                       ACCOUNT_DEPTH)

\* STORAGE ISOLATION
\* [Why]: Contract A's storage must be completely independent of
\* Contract B's storage. Each contract's storage trie is a self-
\* contained SMT whose root depends only on that contract's own data.
\* Verified by proof completeness: every slot position in every alive
\* contract's storage trie has a valid Merkle proof.
\*
\* This also verifies GetStorage semantics: any storage read can be
\* accompanied by a valid Merkle proof for on-chain verification.
\*
\* [Source: 0-input/REPORT.md -- "StorageIsolation: Contract storage
\*          isolated between contracts"]
StorageIsolation ==
    \A c \in Contracts : alive[c] =>
        \A s \in StorageLeafIndices :
            LET val      == EntryValue(storageData[c], s)
                leafH    == LeafHash(s, val)
                siblings == ProofSiblings(storageData[c], s, STORAGE_DEPTH)
                pathBits == PathBitsForKey(s, STORAGE_DEPTH)
            IN VerifyProof(storageRoots[c], leafH, siblings, pathBits,
                           STORAGE_DEPTH)

\* BALANCE CONSERVATION
\* [Why]: No state transition may create or destroy value. The total
\* balance across all accounts must equal the initial supply at all
\* times. This is a fundamental economic safety property.
\*
\* Proof sketch (by action analysis):
\*   - Init: single EOA holds MaxBalance, all others hold 0.
\*   - CreateAccount: sets balance to 0, total unchanged.
\*   - Transfer: from loses amount, to gains amount, net zero.
\*   - SetStorage: no balance change.
\*   - SelfDestruct: contract balance -> beneficiary, net zero.
\*
\* [Source: 0-input/REPORT.md -- EVM balance transfer semantics]
BalanceConservation == TotalBalance = MaxBalance

====
