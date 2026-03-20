Genera un paper academico en LaTeX para el experimento RU-L4 (State Database).

CONTEXTO:
- Paper ID: BNR-2026-010
- Empresa: Base Computing S.A.S., NIT 901872120-5
- Autor: Sebastian Tobar Quintero (sebastian@basisnetwork.co)
- Web: https://basisnetwork.com.co

SOURCE: zkl2/research/experiments/2026-03-19_state-database/ (findings.md, results/, code/)

OUTPUT:
- LaTeX: zkl2/research/experiments/2026-03-19_state-database/paper/src/*.tex
- PDF: zkl2/research/experiments/2026-03-19_state-database/paper/BNR-2026-010.pdf
- Compilar: cd paper/src && pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex && cp main.pdf ../BNR-2026-010.pdf

FORMATO: IEEEtran conference. Header BNR-2026-010 / Basis Network Research. Footer: Basis Network Research -- Internal Technical Report. No emojis. Secciones estandar. Incluir benchmarks Go SMT+Poseidon2, comparacion MPT vs SMT, gnark-crypto results.

NO hagas commits.
