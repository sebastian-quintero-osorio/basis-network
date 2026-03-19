Estandariza el paper del experimento state-commitment.

Paper en validium/research/experiments/2026-03-18_state-commitment/paper/

1. Lee PAPER_GUIDE.md -- sigue TODAS sus instrucciones (BNR-2026-003, Internal Technical Report)
2. Agrega institutional header, paper ID, classification footer
3. Revisa que no haya overflows de tablas ni numeros largos
4. Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
5. Copia: cp main.pdf BNR-2026-003_l1-state-commitment-gas-analysis.pdf

NO hagas commits.
