Corrige de forma definitiva las tablas del paper state-transition-circuit.

Paper en validium/research/experiments/2026-03-18_state-transition-circuit/paper/

PROBLEMA PERSISTENTE: En IEEEtran conference (two-column), las tablas se amontonan y el texto no fluye debajo de ellas sino al lado. Esto afecta Tablas I, II, IV, V, VI, VII.

SOLUCION DEFINITIVA: Cambia TODAS las tablas que tengan problemas a table* (full-width, spans both columns). En IEEEtran two-column, table* ocupa el ancho completo de la pagina y el texto SIEMPRE fluye debajo, no al lado.

Para CADA tabla problematica:
- Cambia \begin{table}[htbp] a \begin{table*}[htbp]
- Cambia \end{table} a \end{table*}
- Si la tabla es angosta, usa \centering y dejala como esta (se vera centrada en el ancho completo)

ALTERNATIVA: Si table* causa que las tablas se vayan a otra pagina, entonces asegurate de que haya suficiente texto entre tablas usando \FloatBarrier (requiere package placeins: \usepackage[section]{placeins}).

Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
Copia: cp main.pdf BNR-2026-002_state-transition-circuit-benchmarks.pdf

VERIFICA visualmente que el texto debajo de cada tabla empiece correctamente alineado a la izquierda, NO al lado de la tabla.

NO hagas commits.
