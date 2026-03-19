Corrige overflow de invariantes en el paper enterprise-node.

Paper en validium/research/experiments/2026-03-18_enterprise-node/paper/

PROBLEMA: Los textos de INV-NO1 y posiblemente otros invariantes tienen overflow hacia la IZQUIERDA de la columna. En la columna derecha, esto causa que el texto se superponga con la columna izquierda.

CAUSA PROBABLE: Los invariantes usan un formato con label (INV-NO1, etc.) que tiene indentacion negativa o un \makebox que se sale del margen izquierdo.

SOLUCION: Busca donde se definen los invariantes (probablemente en methodology.tex o system-model.tex). Si usan:
- \noindent\textbf{INV-NO1}: ... -> Asegurate de que no hay \hspace negativo
- description environment -> Cambia a itemize o enumerate con labels cortos
- \hangindent -> Puede causar overflow hacia la izquierda

ALTERNATIVA: Usa un itemize o enumerate simple:
\begin{itemize}
\item[\textbf{INV-NO1}] texto del invariante...
\end{itemize}

O usa \begin{description} con \item[INV-NO1] que maneja bien el indentation.

Verifica que NINGUN texto se superponga entre columnas.

Compila: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
Copia: cp main.pdf BNR-2026-005_enterprise-node-orchestration.pdf

NO hagas commits.
