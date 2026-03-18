# Glossary -- Formal Verification

| Term | Definition |
|------|-----------|
| Admitted | Coq keyword accepting a theorem without proof. Forbidden in production |
| Common.v | Shared standard library with TLA+ and implementation type mappings |
| Impl.v | Coq file modeling the implementation abstractly |
| Inductive | A Coq data type defined by constructors (similar to Rust enum) |
| Refinement | Proving a concrete implementation satisfies an abstract specification |
| Refinement.v | Coq file with mapping functions and the core refinement theorem |
| Spec.v | Coq file faithfully translating the TLA+ specification |
| Verification Unit | Self-contained directory with frozen spec, impl, proofs, and reports |
