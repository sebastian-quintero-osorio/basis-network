Corrige las tablas del paper state-transition-circuit. Las tablas son DEMASIADO ANCHAS ahora.

Paper en validium/research/experiments/2026-03-18_state-transition-circuit/paper/

PROBLEMA: Las tablas se cambiaron a table* (ancho completo de pagina) pero son tablas pequenas que caben perfectamente en una sola columna. Ahora se ven estiradas y feas.

SOLUCION:
1. Cambia TODAS las table* de vuelta a table (single column)
2. Mantiene [htbp] como float specifier
3. Mantiene \usepackage[section]{placeins} -- esto es lo que realmente arregla el flujo de texto
4. Agrega \FloatBarrier despues de cada tabla si es necesario para forzar que el texto empiece debajo
5. Elimina cualquier \resizebox{\textwidth} -- no es necesario para tablas de una columna
6. Si alguna tabla es ligeramente mas ancha que la columna, usa \resizebox{\columnwidth}{!}{...} en vez de \textwidth

El resultado debe verse como tablas normales de una columna IEEE, compactas y bien formateadas, con el texto fluyendo correctamente debajo de cada una.

Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
Copia: cp main.pdf BNR-2026-002_state-transition-circuit-benchmarks.pdf

NO hagas commits.
