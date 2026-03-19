Estandariza el paper de investigacion del experimento state-transition-circuit.

El paper esta en validium/research/experiments/2026-03-18_state-transition-circuit/paper/

QUE HACER:

1. Lee PAPER_GUIDE.md en paper/ -- sigue TODAS sus instrucciones:
   - Agrega el institutional header con autor y afiliaciones exactas
   - Agrega el paper ID (BNR-2026-002) en el header
   - Agrega el classification footer: "Basis Network Research -- Workshop Paper"
   - Asegura formato Workshop tier (6-8 paginas)
2. Revisa que NO haya errores de LaTeX ni desbordes de tablas/numeros
3. Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
4. Copia: cp main.pdf BNR-2026-002_state-transition-circuit-benchmarks.pdf

NO hagas commits.
