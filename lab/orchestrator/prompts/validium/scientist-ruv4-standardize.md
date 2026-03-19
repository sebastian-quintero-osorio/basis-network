Estandariza el paper del experimento batch-aggregation.

Paper en validium/research/experiments/2026-03-18_batch-aggregation/paper/

IMPORTANTE: Este es un paper PUBLICABLE (Peer-Reviewed Publication Track). Debe tener la maxima calidad.

1. Lee PAPER_GUIDE.md -- sigue TODAS sus instrucciones (BNR-2026-004, Publishable)
2. Agrega institutional header, paper ID, classification footer "Peer-Reviewed Publication Track"
3. Agrega la seccion de reproducibility si no existe (instrucciones para replicar el TLC counterexample)
4. Revisa que no haya overflows de tablas ni numeros largos
5. Revisa calidad de escritura academica (formal, sin emojis, profesional)
6. Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
7. Copia: cp main.pdf BNR-2026-004_crash-safe-batch-aggregation.pdf

NO hagas commits.
