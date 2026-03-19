Corrige los labels de invariantes en DOS papers que tienen el mismo problema.

PROBLEMA: Los labels INV-NOx (paper enterprise-node) e INV-DAx (paper data-availability) se superponen con el texto de la misma columna. El label queda SOBRE el texto del invariante en la misma linea.

PAPERS A CORREGIR:
1. validium/research/experiments/2026-03-18_enterprise-node/paper/ (INV-NO1 a INV-NO6)
2. validium/research/experiments/2026-03-18_data-availability-committee/paper/ (INV-DA1 a INV-DA5)

SOLUCION: El problema es que description environment con labels largos como [INV-NO1] o [INV-DA1] no tiene suficiente espacio para el label y el texto se superpone.

Opcion 1 (preferida): Usa un formato manual sin description:
\noindent\textbf{INV-NO1} (Liveness): texto del invariante...

\noindent\textbf{INV-NO2} (Safety): texto del invariante...

Con un \vspace{2pt} o \smallskip entre cada uno.

Opcion 2: Usa description con labelwidth ajustado:
\begin{description}[leftmargin=2.5cm, labelwidth=2.3cm, labelsep=0.2cm]
\item[INV-NO1] texto...
\end{description}
(requiere enumitem package: \usepackage{enumitem})

Aplica la solucion en AMBOS papers. Busca en methodology.tex, system-model.tex, o donde esten definidos los invariantes.

Compila AMBOS papers y copia los PDFs con nombres estandarizados:
- Paper 5: cp main.pdf BNR-2026-005_enterprise-node-orchestration.pdf
- Paper 6: cp main.pdf BNR-2026-006_shamir-dac-information-theoretic-privacy.pdf

NO hagas commits.
