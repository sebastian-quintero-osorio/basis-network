Estandariza el paper del experimento enterprise-node.

Paper en validium/research/experiments/2026-03-18_enterprise-node/paper/

1. Lee PAPER_GUIDE.md (BNR-2026-005, Internal Technical Report)
2. Agrega institutional header, paper ID, classification footer
3. Revisa overflows de tablas. Usa table[htbp] siempre, NUNCA wraptable.
4. Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
5. Copia: cp main.pdf BNR-2026-005_enterprise-node-orchestration.pdf

NO hagas commits.
