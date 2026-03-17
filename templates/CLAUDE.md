# Project Context for Claude (Hybrid Workflow)

<!-- ============================================================
  This file accumulates project context so that each Claude session
  (outside the secure environment) starts with full background.

  Update this file as the project evolves. Paste its contents at the
  start of every Claude conversation to minimize round-trips.

  DO NOT put any of the following in this file:
  - Actual genomic data (sequences, variants, phenotypes)
  - Patient identifiers or sample IDs linked to patients
  - Access credentials, API keys, internal hostnames
  - Any information derived from or linkable to individual patients
============================================================ -->

## Project overview

<!-- One paragraph describing what this project does -->

## Tech stack

<!-- Languages, frameworks, tools, and their versions -->
- Language:
- Framework:
- Pipeline manager: (e.g., Nextflow, Snakemake, CWL)
- Key libraries:
- Python version:
- OS:

## Directory structure

<!-- Paste output of: tree -L 2 --dirsfirst -->
```
```

## Data schemas

<!-- Describe input/output file formats, column names, data types.
     Use GENERIC column names only (e.g., chrom, pos, ref, alt).
     NEVER paste actual data values. -->

### Input files
- Format:
- Key fields:

### Output files
- Format:
- Key fields:

## Existing code patterns

<!-- Describe conventions the project already follows so Claude's
     suggestions stay consistent. -->
- Naming conventions:
- Error handling pattern:
- Testing approach:
- Logging:

## Current goals

<!-- What are you trying to accomplish right now? -->

## Known constraints

<!-- Anything Claude should know that isn't obvious from the code.
     e.g., "must run on CPU-only", "FASTQ files are >100GB",
     "pipeline must complete within 24h" -->

## History of changes

<!-- Brief log of what Claude helped with in previous sessions,
     so new sessions don't repeat or undo prior work. -->

| Date | What was done | Key decisions |
|------|--------------|---------------|
|      |              |               |
