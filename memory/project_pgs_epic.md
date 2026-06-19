---
name: project-pgs-epic
description: PGS-EPIC pipeline structure, GitHub-readiness work, and key design decisions
metadata:
  type: project
---

Pipeline for calculating Polygenic Scores (PGS) on the EPIC cohort using pgsc_calc (Nextflow). Target users are any researchers with PLINK-format genetics data and access to an HPC cluster with SLURM + Singularity.

**Repository structure established:**
- `pipeline/PGS.sh` — core `calculate_pgs()` bash function (refactored from `src/PGS.sh`)
- `pipeline/pgsc_calc.config` — SLURM resource config for Nextflow
- `config/site.conf.example` — template for user-specific paths (committed)
- `config/site.conf` — user fills in locally, gitignored
- `setup.sh` — auto-installs Java 21 (Adoptium) + Nextflow into `tools/`; creates site.conf
- `run.sh` — user entry point; sources site.conf, sets PATH, sources pipeline/PGS.sh, calls calculate_pgs
- `.gitignore` — ignores site.conf, tools/, work/, .nextflow/, docs generated files

**Key env vars expected by pipeline/PGS.sh:**
- `GENETICS_PATH` — PLINK prefix path (no extension)
- `NXF_SINGULARITY_CACHEDIR` — Singularity image cache directory
- `PGSC_CONFIG` — path to pgsc_calc.config (set by run.sh automatically)
- `SAMPLESET_NAME` — optional, defaults to "combined"
- `TARGET_BUILD` — optional, defaults to "GRCh37"

**Old `src/` directory** still exists with the original hardcoded scripts — can be deleted before first GitHub push.

**Why:** Goal was to make the project cloneable and usable by anyone in the EPIC consortium (or with their own genetics data) without requiring manual path editing inside the script files.
