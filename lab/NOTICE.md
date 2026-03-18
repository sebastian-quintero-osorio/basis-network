# Basis Network R&D Laboratory -- Disclosure Notice

## Proprietary Components

This directory contains the infrastructure for the Basis Network 4-agent R&D pipeline. Certain components are excluded from this public repository because they constitute core intellectual property of Base Computing S.A.S.

### What is excluded

- **CLAUDE.md files**: The operating manuals that define each agent's behavior, constraints, methodology, and domain knowledge. These files encode the research methodology, quality gates, and decision frameworks that drive the pipeline's output quality.

- **Skills (.claude/commands/)**: The procedural workflows that implement the operating manual rules. These define the exact step-by-step protocols for experimentation, formalization, implementation, and verification.

Each agent directory contains a `CLAUDE.md.example` file documenting the purpose and expected structure of the excluded configuration.

### What is included

Everything the pipeline produces is public and auditable:

- **Foundations**: Living documents tracking system invariants and threat models
- **Research history**: Formal TLA+ specifications and model checking artifacts
- **Implementation history**: Verified implementation records
- **Verification history**: Coq proof artifacts
- **Documentation**: Glossaries, ADRs, architecture documents

The pipeline's outputs -- papers, specifications, code, and proofs -- are fully transparent. Only the operational configuration that drives the agents is proprietary.

### Why

The 4-agent pipeline (Scientist, Logicist, Architect, Prover) represents a novel approach to autonomous blockchain R&D. The methodology, quality gates, and inter-agent protocols are the result of extensive research and iteration. They are a competitive advantage that enables Base Computing to develop formally verified blockchain infrastructure at a pace and rigor level that would otherwise require significantly larger teams.

Protecting these operational configurations is consistent with our Business Source License 1.1 approach: the outputs are open, the methodology is proprietary.

### Contact

For inquiries about the R&D pipeline or licensing:
- **Company**: Base Computing S.A.S.
- **Contact**: social@basecomputing.com.co
