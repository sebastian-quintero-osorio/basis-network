# Paper Guide -- Shamir-DAC Information-Theoretic Privacy (RU-V6)

## Classification

**Tier: PUBLISHABLE (Research Contribution)**

This paper presents the first DAC design with information-theoretic data privacy.
The claim "no production DAC has data privacy" is verifiable and correct. Shamir
(k,n)-threshold secret sharing replaces full data replication, providing the
strongest possible privacy guarantee -- unconditional, not computational.

## What the Scientist Must Do

1. **Standardize the LaTeX format** to the Basis Network Research template (see below)
2. **Add institutional header** with author affiliations and contact
3. **Add paper identifier**: BNR-2026-006 (Basis Network Research, year, sequential)
4. **Add classification footer**: "Basis Network Research -- Peer-Reviewed Publication Track"
5. **Ensure Table I (production DAC comparison)** is prominently placed and complete
   (StarkEx, Polygon CDK, Arbitrum Nova, EigenDA, Celestia -- all lack data privacy)
6. **Strengthen the security model**: Add formal game-based definition of privacy
   (simulator-based or indistinguishability-based)
7. **Ensure all 24 references are properly formatted**
8. **Compile clean PDF**

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

**Affiliations block**:
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

- **ID**: BNR-2026-006
- **Series**: Basis Network Research Papers
- **Date**: March 2026
- **Status**: Peer-Reviewed Publication Track

## Format Standard (Publishable Tier)

- **Document class**: IEEEtran, conference mode
- **Sections**: Abstract, Introduction, Related Work, System Model, Methodology,
  Experimental Setup, Results, Discussion, Conclusion, References
- **Abstract**: 200-250 words
- **References**: 20+ entries, BibTeX
- **Page limit**: 8-10 pages
- **Language**: English, formal academic prose, no emojis
- **Tables/Figures**: All numbered, captioned, referenced in text
- **Paper ID in header**: "BNR-2026-006"

## Target Venues (for future adaptation)

- IEEE Blockchain
- ACM CCS Workshop (Privacy Track)
- FC Applied Cryptography Track

## Peer Papers in This Tier

This paper shares the Publishable tier with RU-V4 (NoLoss Bug, BNR-2026-004).
Both must use identical formatting, institutional headers, and classification footers.
