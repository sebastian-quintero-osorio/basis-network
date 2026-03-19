Corrige problemas visuales en el paper sparse-merkle-tree.

El paper esta en validium/research/experiments/2026-03-18_sparse-merkle-tree/paper/

PROBLEMAS A CORREGIR:

1. En la seccion "B. Sparse Merkle Tree Design" hay un numero BN128 prime que se desborda del margen:
   p = 2188824287183927522224640574525727508854836440041603...
   SOLUCION: Usa \small o \footnotesize para el numero, o ponlo en una linea separada con math mode y un line break. Alternativa: usa notacion cientifica o simplemente cita "the BN128 scalar field (a 254-bit prime)" sin el numero completo.

2. Tabla III se desborda un poco (demasiado ancha).
   SOLUCION: Reduce el tamano de fuente de la tabla con \small o \footnotesize dentro del tabular, o ajusta las columnas.

3. Tabla VIII tambien se desborda.
   SOLUCION: Misma solucion, reduce font size o ajusta columnas.

Despues de corregir:
- Compila el PDF: pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
- Copia: cp main.pdf BNR-2026-001_sparse-merkle-tree-poseidon.pdf

NO hagas commits.
