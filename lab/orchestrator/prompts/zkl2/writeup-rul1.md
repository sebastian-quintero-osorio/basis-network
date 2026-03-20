Genera un paper academico en LaTeX para el experimento RU-L1 (EVM Executor).

CONTEXTO:
- El Scientist del zkl2 pipeline completo los 11 experimentos de investigacion
- Cada experimento tiene findings.md con resultados completos
- El Validium ya tiene 7 papers (BNR-2026-001 a BNR-2026-007)
- Este es el primero de 8 papers del zkl2 (BNR-2026-008)
- La empresa es Base Computing S.A.S. (Medellin, Colombia)
- NIT: 901872120-5
- Autor: Sebastian Tobar Quintero (sebastian@basisnetwork.co)
- Web: https://basisnetwork.com.co
- Proyecto: Basis Network

SOURCE MATERIAL:
- Findings: zkl2/research/experiments/2026-03-19_evm-executor/findings.md
- Results: zkl2/research/experiments/2026-03-19_evm-executor/results/
- Code: zkl2/research/experiments/2026-03-19_evm-executor/code/

OUTPUT:
- Directorio: zkl2/research/experiments/2026-03-19_evm-executor/paper/src/ (archivos .tex)
- PDF: zkl2/research/experiments/2026-03-19_evm-executor/paper/ (compilar con pdflatex)

FORMATO:
- IEEEtran conference format
- Paper ID: BNR-2026-008
- Header: "BNR-2026-008" izquierda, "Basis Network Research" derecha
- Footer: "Basis Network Research -- Internal Technical Report. Web: https://basisnetwork.com.co"
- Secciones: Abstract, Introduction, Related Work, System Model/Methodology, Experimental Setup, Results, Discussion, Conclusion, References
- Titulo descriptivo basado en el contenido de findings.md
- Incluir todas las tablas de benchmark del findings
- Incluir invariantes descubiertos
- Referencias: usar todas las citadas en findings.md
- No emojis
- Compilar el PDF con: pdflatex main.tex && pdflatex main.tex

CALIDAD:
- Lenguaje academico profesional
- Tablas formateadas con booktabs
- Cada claim soportado por datos o referencia
- Sin BN128 prime overflow (usar notacion cientifica o nombrar el campo)

NO hagas commits.
