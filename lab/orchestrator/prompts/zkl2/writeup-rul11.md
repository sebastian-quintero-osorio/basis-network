Genera un paper academico en LaTeX para el experimento hub-and-spoke.

Paper ID: BNR-2026-015. Titulo sugerido: Cross-Enterprise Hub-and-Spoke Protocol.
Empresa: Base Computing S.A.S., NIT 901872120-5. Autor: Sebastian Tobar Quintero (sebastian@basisnetwork.co). Web: https://basisnetwork.com.co

SOURCE: zkl2/research/experiments/2026-03-19_hub-and-spoke/ (findings.md, results/, code/)

OUTPUT:
- LaTeX: zkl2/research/experiments/2026-03-19_hub-and-spoke/paper/src/*.tex
- PDF: zkl2/research/experiments/2026-03-19_hub-and-spoke/paper/BNR-2026-015.pdf
- Compilar: cd paper/src && pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex && cp main.pdf ../BNR-2026-015.pdf

FORMATO: IEEEtran conference. Header BNR-2026-015 / Basis Network Research. Footer: Basis Network Research -- Internal Technical Report. No emojis. Incluir TODAS las tablas de benchmark y invariantes del findings.md.

NO hagas commits.
