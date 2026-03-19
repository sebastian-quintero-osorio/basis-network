Corrige problemas de overflow en el paper batch-aggregation.

Paper en validium/research/experiments/2026-03-18_batch-aggregation/paper/

PROBLEMAS:

1. Tabla 5 se sale de la columna y choca con la segunda columna.
   SOLUCION: Usa \resizebox{\columnwidth}{!}{...} o reduce font con \small.

2. Las rutas de archivos se desbordan en la seccion de Reproducibility:
   - "validium/research/experiments/2026-03-18_bat..." se sale
   - "validium/specs/units/2026-03-batch-a..." se sale
   - "v0-analysis/experiments/BatchAggregati..." se sale
   SOLUCION: Usa \url{} con el paquete url, o usa \path{} con \usepackage{url},
   o pon las rutas en un \begin{small}\texttt{...}\end{small} con \allowbreak
   o simplemente usa \seqsplit{} del paquete seqsplit.
   ALTERNATIVA MAS SIMPLE: Pon las rutas dentro de \begin{verbatim}...\end{verbatim}
   que hace line-break automatico, o usa \begin{lstlisting}...\end{lstlisting}.

Despues de corregir:
- Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
- Copia: cp main.pdf BNR-2026-004_crash-safe-batch-aggregation.pdf

NO hagas commits.
