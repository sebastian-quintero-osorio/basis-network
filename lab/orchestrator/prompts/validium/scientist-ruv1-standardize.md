Estandariza el paper de investigacion del experimento sparse-merkle-tree.

CONTEXTO:
- El paper ya existe en validium/research/experiments/2026-03-18_sparse-merkle-tree/paper/
- Tiene main.tex, secciones separadas (.tex), references.bib, y un main.pdf compilado
- DEBES leer el archivo PAPER_GUIDE.md en esa misma carpeta paper/ -- contiene las instrucciones exactas de lo que debes hacer, incluyendo el tier de clasificacion, la informacion institucional, el paper ID, y el formato estandar

QUE HACER:

1. Lee PAPER_GUIDE.md en la carpeta paper/ del experimento
2. Sigue TODAS las instrucciones del PAPER_GUIDE.md:
   - Agrega el institutional header con el autor y afiliaciones exactas
   - Agrega el paper ID (BNR-2026-NNN) en el header del documento
   - Agrega el classification footer correspondiente al tier
   - Asegura que el formato cumple con el estandar del tier
3. Revisa que NO haya errores de LaTeX:
   - Todas las referencias (\ref, \cite) resueltas
   - Todas las tablas con caption y numeracion
   - Sin warnings de compilacion
4. Renombra el PDF final con un nombre estandarizado y descriptivo:
   - Formato: BNR-2026-NNN_titulo-corto.pdf
   - Ejemplo: BNR-2026-001_sparse-merkle-tree-poseidon.pdf
   - Mantiene main.pdf como el archivo de compilacion pero copia con el nombre estandarizado
5. Compila el PDF final:
   - cd paper/
   - pdflatex main.tex
   - bibtex main
   - pdflatex main.tex
   - pdflatex main.tex
   - Copia: cp main.pdf BNR-2026-NNN_titulo-corto.pdf

NO hagas commits de git. Comienza con /writeup
