Corrige problemas de tablas en el paper state-transition-circuit.

Paper en validium/research/experiments/2026-03-18_state-transition-circuit/paper/

PROBLEMA: En las Tablas I, II, III, IV, VI, y VII el texto que deberia ir justo debajo de la tabla NO empieza debajo sino que empieza a la derecha de la tabla, quitandole espacio. Esto ocurre cuando las tablas usan \begin{table} sin [htbp] o cuando usan wraptable o similar.

SOLUCION: Asegurate de que TODAS las tablas usen:
\begin{table}[htbp]
  \centering
  \caption{...}
  \begin{tabular}{...}
  ...
  \end{tabular}
  \label{...}
\end{table}

NO uses \begin{wraptable} ni \begin{wrapfigure}.
Cada tabla debe ser un float completo que ocupe el ancho de la columna.
Si alguna tabla es demasiado ancha, usa \resizebox{\columnwidth}{!}{...} dentro del table environment.

Despues de corregir:
- Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
- Copia: cp main.pdf BNR-2026-002_state-transition-circuit-benchmarks.pdf

NO hagas commits.
