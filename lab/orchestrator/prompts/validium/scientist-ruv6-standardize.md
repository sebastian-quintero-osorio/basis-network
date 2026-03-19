Estandariza el paper del experimento data-availability-committee.

Paper en validium/research/experiments/2026-03-18_data-availability-committee/paper/

IMPORTANTE: Este es un paper PUBLICABLE (Peer-Reviewed Publication Track). Maxima calidad.

1. Lee PAPER_GUIDE.md (BNR-2026-006, Publishable)
2. Agrega institutional header, paper ID, classification footer "Peer-Reviewed Publication Track"
3. Revisa overflows. Usa table[htbp] o table*[htbp] para tablas anchas. NUNCA wraptable.
4. Usa \resizebox para tablas que se salgan de la columna.
5. Revisa rutas largas: usa \url{} o \path{} si hay paths de archivos.
6. Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
7. Copia: cp main.pdf BNR-2026-006_shamir-dac-information-theoretic-privacy.pdf

NO hagas commits.
