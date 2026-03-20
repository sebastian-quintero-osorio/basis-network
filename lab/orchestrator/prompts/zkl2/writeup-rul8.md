Genera un paper academico en LaTeX para el experimento production-dac.

Paper ID: BNR-2026-012. Titulo sugerido: Production DAC with Erasure Coding.
Empresa: Base Computing S.A.S., NIT 901872120-5. Autor: Sebastian Tobar Quintero (sebastian@basisnetwork.co). Web: https://basisnetwork.com.co

SOURCE: zkl2/research/experiments/2026-03-19_production-dac/ (findings.md, results/, code/)

OUTPUT:
- LaTeX: zkl2/research/experiments/2026-03-19_production-dac/paper/src/*.tex
- PDF: zkl2/research/experiments/2026-03-19_production-dac/paper/BNR-2026-012.pdf
- Compilar: cd paper/src && pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex && cp main.pdf ../BNR-2026-012.pdf

FORMATO: IEEEtran conference. Header BNR-2026-012 / Basis Network Research. Footer: Basis Network Research -- Internal Technical Report. No emojis. Incluir TODAS las tablas de benchmark y invariantes del findings.md.

NO hagas commits.
