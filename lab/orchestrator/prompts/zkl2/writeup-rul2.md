Genera un paper academico en LaTeX para el experimento RU-L2 (Sequencer and Block Production).

CONTEXTO:
- Pipeline zkl2 completo (44/44 items). Generando papers faltantes.
- Paper ID: BNR-2026-009 (continua de BNR-2026-008)
- Empresa: Base Computing S.A.S. (Medellin, Colombia), NIT 901872120-5
- Autor: Sebastian Tobar Quintero (sebastian@basisnetwork.co)
- Web: https://basisnetwork.com.co

SOURCE MATERIAL:
- Findings: zkl2/research/experiments/2026-03-19_sequencer/findings.md
- Results: zkl2/research/experiments/2026-03-19_sequencer/results/ (15 benchmark files)
- Code: zkl2/research/experiments/2026-03-19_sequencer/code/

OUTPUT:
- LaTeX: zkl2/research/experiments/2026-03-19_sequencer/paper/src/*.tex
- PDF: zkl2/research/experiments/2026-03-19_sequencer/paper/BNR-2026-009.pdf
- Compilar con: cd paper/src && pdflatex main.tex && bibtex main && pdflatex main.tex && pdflatex main.tex && cp main.pdf ../BNR-2026-009.pdf

FORMATO:
- IEEEtran conference, mismo template que BNR-2026-008
- Header: BNR-2026-009 izquierda, Basis Network Research derecha
- Footer: Basis Network Research -- Internal Technical Report. Web: https://basisnetwork.com.co
- Secciones: Abstract, Introduction, Related Work, System Model, Methodology, Results, Discussion, Conclusion, References
- Incluir TODAS las tablas de benchmark
- Incluir invariantes (forced inclusion, FIFO ordering, MEV analysis)
- No emojis, no BN128 overflow

NO hagas commits.
