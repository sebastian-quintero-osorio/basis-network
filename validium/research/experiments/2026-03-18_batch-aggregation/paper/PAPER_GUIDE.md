# Paper Guide -- Crash-Safe Batch Aggregation (RU-V4)

## Classification

**Tier: PUBLISHABLE (Research Contribution)**

This paper documents the discovery of a critical crash-recovery bug by TLA+ model
checking that 150+ empirical tests missed. The bug-finding narrative is a concrete
case study for the "formal verification vs testing" debate -- a recognized research
topic. The deferred checkpoint protocol is a practical contribution.

## What the Scientist Must Do

1. **Standardize the LaTeX format** to the Basis Network Research template (see below)
2. **Add institutional header** with author affiliations and contact
3. **Add paper identifier**: BNR-2026-004 (Basis Network Research, year, sequential)
4. **Add classification footer**: "Basis Network Research -- Peer-Reviewed Publication Track"
5. **Strengthen reproducibility**: Add a section or appendix with exact instructions to
   replicate the TLC counterexample (command, config, expected output)
6. **Strengthen related work**: Cite Newcombe et al. 2015 ("How Amazon Web Services Uses
   Formal Methods") and Lamport 2002 (Specifying Systems) as TLA+ case studies
7. **Ensure all tables have proper captions and are referenced in text**
8. **Compile clean PDF** (zero warnings, zero missing references)

## Author and Institutional Information

Use this EXACT information in the paper header:

```latex
\author{
  Sebastian Tobar Quintero \\
  Basis Network Research \\
  Base Computing S.A.S. \\
  Medell\'{i}n, Colombia \\
  sebastian@basisnetwork.co
}
```

**Affiliations block** (for multi-line IEEE format):
- Primary: Basis Network Research, Medell\'{i}n, Colombia
- Institution: Base Computing S.A.S. (NIT: 901872120-5)
- In alliance with: Basis Network Foundation

**Footer/acknowledgment**:
```
This work was produced by the Basis Network Automated R\&D Laboratory,
a 4-agent research pipeline operated by Base Computing S.A.S.
Web: https://basisnetwork.com.co
```

## Paper Identifier

- **ID**: BNR-2026-004
- **Series**: Basis Network Research Papers
- **Date**: March 2026
- **Status**: Peer-Reviewed Publication Track

## Format Standard (Publishable Tier)

- **Document class**: IEEEtran, conference mode
- **Sections**: Abstract, Introduction, Related Work, System Model, Methodology,
  Results, Discussion, Conclusion, References
- **Abstract**: 200-250 words
- **References**: 20+ entries, BibTeX
- **Page limit**: 8-10 pages (IEEE conference standard)
- **Language**: English, formal academic prose, no emojis
- **Tables/Figures**: All numbered, captioned, referenced in text
- **Paper ID in header**: "BNR-2026-004"

## Target Venues (for future adaptation, not for current formatting)

- ICSE-SEIP (Software Engineering in Practice)
- ABZ Workshop (Abstract State Machines, Alloy, B, TLA, VDM, Z)
- FC Workshop (Financial Cryptography)
- IEEE Blockchain (Industry Track)

## Peer Papers in This Tier

This paper shares the Publishable tier with RU-V6 (Shamir-DAC, BNR-2026-006).
Both must use identical formatting, institutional headers, and classification footers.
