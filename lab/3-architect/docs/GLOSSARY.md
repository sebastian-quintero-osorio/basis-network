# Glossary -- Implementation

| Term | Definition |
|------|-----------|
| Batch Aggregator | Component grouping individual transactions into provable batches |
| DAC | Data Availability Committee ensuring data recoverability |
| Delta Analysis | Identifying the gap between formal spec and current codebase |
| Enterprise Node | Application-specific L2 execution environment per enterprise |
| Escape Hatch | L1 mechanism for forced withdrawal if L2 operator fails |
| Implementation History Unit | Verified TLA+ spec + proof driving a codebase evolution |
| Safety Latch | Mandatory TLA+ proof verification before any code is written |
| Sequencer | Component ordering enterprise transactions within a batch |
| Sparse Merkle Tree | Tree enabling efficient state proofs with sparse key spaces |
| State Root | Cryptographic hash summarizing complete enterprise state |
| Submitter | Component posting proofs and state roots to L1 |
| Validium | L2 where data stays off-chain, only proofs posted on-chain |
