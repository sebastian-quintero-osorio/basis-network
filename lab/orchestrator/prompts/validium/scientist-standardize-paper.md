Estandariza el paper de investigacion del experimento indicado.

EXPERIMENTO: $ARGUMENTS

CONTEXTO:
- El paper ya existe en validium/research/experiments/$ARGUMENTS/paper/
- Tiene main.tex, secciones separadas (.tex), references.bib, y un main.pdf compilado
- DEBES leer el archivo PAPER_GUIDE.md en esa misma carpeta paper/ -- contiene las instrucciones exactas

QUE HACER:

1. Lee PAPER_GUIDE.md en paper/ -- sigue TODAS sus instrucciones:
   - Agrega el institutional header con autor y afiliaciones exactas
   - Agrega el paper ID (BNR-2026-NNN) en el header
   - Agrega el classification footer del tier correspondiente
   - Asegura formato del tier (paginas, abstract length, references count)
2. Revisa que NO haya errores de LaTeX:
   - Todas las \ref y \cite resueltas
   - Todas las tablas con caption y numeracion
   - Sin warnings de compilacion (o solo float placement)
3. Compila el PDF final:
   - cd validium/research/experiments/$ARGUMENTS/paper/
   - pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex
4. Renombra con nombre estandarizado:
   - Formato: BNR-2026-NNN_slug-descriptivo.pdf
   - Copia: cp main.pdf BNR-2026-NNN_slug.pdf

NO hagas commits de git.
