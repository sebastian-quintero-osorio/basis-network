Estandariza el paper del experimento cross-enterprise.

Paper en validium/research/experiments/2026-03-18_cross-enterprise/paper/

1. Lee PAPER_GUIDE.md (BNR-2026-007, Workshop Paper)
2. Agrega institutional header, paper ID, classification footer "Workshop Paper"
3. Revisa overflows: tablas con [htbp] + FloatBarrier, nunca table*. Usa resizebox si necesario.
4. Revisa que invariantes y paths no se desborden.
5. Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
6. Copia: cp main.pdf BNR-2026-007_cross-enterprise-proof-aggregation.pdf

NO hagas commits.
