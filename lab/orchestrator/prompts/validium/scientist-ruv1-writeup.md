Genera el paper academico para el experimento sparse-merkle-tree.

CONTEXTO:
- El experimento esta en validium/research/experiments/2026-03-18_sparse-merkle-tree/
- Stage 1 (Implementation) completo. Hipotesis CONFIRMADA.
- findings.md tiene 449 lineas con 18 referencias, benchmarks reales, comparacion de hash functions
- Resultados clave: insert 1.825ms, proof gen 0.018ms, proof verify 1.744ms, Poseidon 4.97x faster que MiMC
- El paper debe ir en validium/research/experiments/2026-03-18_sparse-merkle-tree/paper/

QUE HACER:

1. Lee findings.md completamente para extraer todos los datos
2. Lee los resultados JSON en results/ para numeros exactos
3. Lee el codigo en code/ para entender la implementacion

4. Escribe el paper en LaTeX con las siguientes secciones (cada una como archivo .tex separado):
   - paper/main.tex (documento maestro que incluye las secciones)
   - paper/abstract.tex
   - paper/introduction.tex
   - paper/related-work.tex
   - paper/methodology.tex
   - paper/results.tex
   - paper/discussion.tex
   - paper/conclusion.tex
   - paper/references.bib (BibTeX)

5. El paper debe ser profesional, nivel conferencia academica:
   - Titulo: "Sparse Merkle Trees with Poseidon Hash for Enterprise ZK Validium State Management"
   - Autores: Base Computing S.A.S. Research Team
   - Abstract: 150-250 palabras
   - Tablas con benchmarks reales (los numeros de findings.md)
   - Comparacion con literatura publicada
   - Formato: IEEE conference style o similar

6. Compila el PDF:
   - cd paper/
   - pdflatex main.tex
   - bibtex main (si hay .bib)
   - pdflatex main.tex
   - pdflatex main.tex
   - Verifica que el PDF se genere sin errores

7. Session log en lab/1-scientist/sessions/

NO hagas commits. Comienza con /writeup
