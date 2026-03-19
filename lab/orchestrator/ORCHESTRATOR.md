# Orchestrator Execution Protocol

> How to autonomously execute the R&D pipeline agents across a roadmap.

## Execution Pattern

For each checklist item in `<target>/ROADMAP_CHECKLIST.md`:

### 1. Write the Prompt File

Create a prompt file BEFORE launching the agent:

```
lab/orchestrator/prompts/<target>/<agent>-<ru_id>.md
```

Example: `lab/orchestrator/prompts/validium/scientist-ruv1.md`

The prompt must include:
- Hypothesis or task description (from the checklist)
- Input locations (where to find upstream materials)
- Output locations (where to write artifacts)
- Quality expectations (benchmarks, invariants, tests)
- Explicit instruction: "NO hagas commits de git"
- The slash command to invoke: `/experiment`, `/1-formalize`, `/implement`, `/verify`

### 2. Launch the Agent

From the agent's directory, run:

```bash
cd lab/<N>-<agent>
claude --dangerously-skip-permissions -p "$(cat ../orchestrator/prompts/<target>/<agent>-<ru>.md)" > /tmp/<agent>_<ru>.log 2>&1
```

Use `run_in_background: true` to avoid blocking.

Key: NO PIPES after the command. Redirect to file only. Pipes cause buffering issues.

### 3. Monitor Progress

Check the target directories for new files every 2-5 minutes:

```bash
find <target>/<output_dir>/ -type f -newermt "<launch_time>" | head -20
```

The agent is done when:
- Session log appears in `lab/<N>-<agent>/sessions/`
- The log file (`/tmp/<agent>_<ru>.log`) has content
- The process exits

### 4. Verify Quality

Before marking complete:
- **Scientist**: findings.md exists, results/ has JSON data, benchmarks are real numbers
- **Logicist**: MC_*.log exists and says "No error has been found", PHASE reports exist
- **Architect**: Tests pass (run `npx jest` or `npx hardhat test` independently), ADVERSARIAL-REPORT.md exists
- **Prover**: All .vo files exist (Coq compiled), SUMMARY.md exists, 0 Admitted

### 5. Handoff

Copy outputs to the next agent's input directory:

| From | To |
|------|----|
| Scientist experiment | `<target>/specs/units/<unit>/0-input/` (for Logicist) |
| Logicist TLA+ spec | Already in place (Architect reads from specs/units/) |
| Architect code | `<target>/proofs/units/<unit>/0-input-impl/` (for Prover) |

### 6. Git Commit

```bash
git checkout -b <type>/<ru>-<component>
git add <specific files>
git commit -m "<conventional commit message>"
git checkout dev
git merge <branch> --no-ff -m "merge: <description>"
git branch -d <branch>
```

### 7. Update Checklist

Mark `- [x] **Complete** (<date> -- <key metric>)` in the checklist.

## Agent Timeout Handling

If an agent times out (log shows "Request timed out"):
1. Check what files were created
2. Re-launch with a more focused prompt (suffix `-retry`)
3. Reference the partial work in the retry prompt

## Critical Gate: Logicist Failures

If TLC finds an invariant violation:
1. This is a DISCOVERY, not a failure
2. The Logicist must execute Phases 3-5 (diagnose, fix, review)
3. Create a separate prompt: `<agent>-<ru>-fix.md`
4. The fixed spec in `v1-fix/` becomes the authoritative version

## Directory Structure

```
lab/orchestrator/
  ORCHESTRATOR.md               # This file
  prompts/
    validium/                   # Prompts for validium roadmap (28 items)
      scientist-ruv1.md
      logicist-ruv1.md
      architect-ruv1.md
      prover-ruv1.md
      ...
    zkl2/                       # Prompts for zkl2 roadmap (44 items)
      scientist-ru01.md
      ...
```
