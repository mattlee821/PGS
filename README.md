# PGS Calculation Pipeline for EPIC

A pipeline for calculating Polygenic Scores (PGS) using PLINK-format genotype data. It wraps the [PGS Catalogue Calculator](https://github.com/PGScatalog/pgsc_calc) (`pgsc_calc`) and is designed for use on HPC clusters with SLURM and Singularity.

## What is a Polygenic Score (PGS)?

A Polygenic Score (PGS), also known as a polygenic risk score, is a numerical value that summarizes the genetic predisposition of an individual to a particular trait or disease. It is calculated by combining the effects of many genetic variants across the genome, each weighted by their association with the trait of interest. PGS can be used to:

- Estimate genetic risk for common diseases
- Predict quantitative traits (e.g., height, BMI)
- Stratify individuals for disease prevention strategies
- Enhance understanding of disease etiology

Scores are derived from genome-wide association studies (GWAS) and are available through the [PGS Catalog](https://www.pgscatalog.org/).

## Prerequisites

- **HPC cluster** with SLURM and Singularity (or Apptainer)
- **PLINK-format genotype data** (`.bed` / `.bim` / `.fam`)
- **Internet access** from the compute nodes (to download Nextflow and PGS scoring files)

Java 17+ and Nextflow are installed automatically by `src/setup.sh` if not already present.

## Repository Structure

```
PGS-EPIC/
├── params.yml.example     # Parameter template — copy to params.yml and fill in
├── params.yml             # Your site-specific parameters (gitignored)
├── src/
│   ├── setup.sh           # One-time setup: installs tools, creates params.yml
│   └── run.sh             # Entry point: loads params.yml, runs the pipeline
├── pipeline/
│   ├── PGS.sh             # Core calculate_pgs() function
│   └── pgsc_calc.config   # SLURM resource configuration for Nextflow
├── logs/
│   ├── setup.log          # Log from src/setup.sh
│   └── run_<timestamp>.log # Invocation record for each src/run.sh call
└── docs/
    └── overview.qmd       # Background and methodology
```

## Quick Start

### Step 1: Clone the repository

```bash
cd ~
git clone https://github.com/mattlee821/PGS.git
cd ~/PGS
```

### Step 2: Run setup

```bash
bash ~/PGS/src/setup.sh
```

This will:
- Install Java 21 and Nextflow into `tools/` if not already available
- Detect and load the Singularity or Apptainer module from the HPC module system
- Create `params.yml` from the template, with `$HOME` paths already expanded

### Step 3: Run the `pgsc_calc` test

Verify the pipeline is working with the bundled pgsc_calc test dataset:

```bash
sbatch --job-name=pgs-test src/run.sh --test
```

Output and logs go to `~/PGS/test/`. This confirms Java, Nextflow, and Singularity/Apptainer are all wired up correctly before using your own data.

### Step 4: Configure parameters

Edit `~/PGS/params.yml`:

```yaml
genetics_path: "/path/to/your/genetics/data_prefix"
target_build: "YOUR-DATA-BUILD" # e.g., "GRCh37"
```

All other parameters are set to sensible defaults (see `params.yml.example` for the full list). If setup could not detect your container module automatically, also fill in `container_module` with the output of `module avail apptainer` or `module avail singularity`.

### Step 5: Run your analysis


`src/run.sh` is a self-contained SBATCH script which you submit directly with `sbatch` from the `~/PGS/` directory. You may need to modify the `#SBATCH` params for your HPC specifics. Otherwise you can submit the job by specifying params directly:

```bash
cd ~/PGS
sbatch --job-name=pgs-PGS000717 src/run.sh --trait "PGS000717" --dir_out ~/PGS/analysis/PGS000717
```

This submits the Nextflow launcher as a SLURM job. Nextflow then submits the actual compute steps as additional SLURM jobs, using the resource limits in `pipeline/pgsc_calc.config`.

SLURM logs are written to `~/PGS/logs/<job-name>.out` and `.err`. With the example above:
- `~/PGS/logs/pgs-PGS000717.out`
- `~/PGS/logs/pgs-PGS000717.err`

## Parameters

### `params.yml`

| Parameter | Required | Default | Description |
|---|---|---|---|
| `genetics_path` | Yes | — | PLINK prefix path (no `.bed`/`.bim`/`.fam` extension) |
| `singularity_cache` | Yes | `~/singularity_cache` | Shared directory for Singularity/Apptainer image cache |
| `container_module` | No | auto-detected | HPC module name for Singularity/Apptainer (e.g. `apptainer`) |
| `sampleset_name` | No | `combined` | Internal sampleset identifier used by pgsc_calc |
| `target_build` | No | `GRCh37` | Genome build of input data (`GRCh37` or `GRCh38`) |
| `min_overlap` | No | `0.75` | Minimum variant overlap fraction (0–1) |

### `src/run.sh` command-line arguments

| Argument | Flag | Description | Required |
|---|---|---|---|
| Test | `--test` | Run the pgsc_calc test profile; output goes to `~/PGS/test/` | — |
| Trait | `-t`, `--trait` | PGS Catalog ID (e.g. `PGS003850`), comma-separated list, or local scorefile path | Yes |
| Output directory | `-o`, `--dir_out` | Directory for logs, working files, and results | Yes |
| Min overlap | `-m`, `--min_overlap` | Overrides the `min_overlap` value in `params.yml` | No |
| Sample filter | `-f`, `--filter_samples` | Single-column, headerless file of sample IDs to retain | No |

### Examples

Run all `sbatch` commands from `~/PGS/`. The `--job-name` sets the log file names (`logs/<job-name>-<job-id>.out`).

```bash
# Multiple PGS Catalog IDs
sbatch --job-name=pgs-test1 src/run.sh --trait "PGS000717,PGS002013" --dir_out ~/PGS/analysis/test1

# Local scorefile
sbatch --job-name=pgs-test2 src/run.sh --trait "~/PGS/scorefile.txt" --dir_out ~/PGS/analysis/test2

# With sample filter
sbatch --job-name=pgs-test3 src/run.sh \
  --trait "PGS000717" \
  --dir_out ~/PGS/analysis/test3 \
  --filter_samples "ids_to_keep.txt" 
```

## Output

```
dir_out/
├── pgs_calculation.log       # Complete pipeline log
├── work/                     # Nextflow working files
│   ├── samplesheet.csv
│   └── results/
└── score/
    ├── aggregated_scores.txt # Final scores (tab-separated)
    └── report.html           # QC report
```

The `aggregated_scores.txt` file contains:

| Column | Description |
|---|---|
| `ID_sample` | Sample identifier |
| `PGS` | PGS accession ID |
| `SUM` | Weighted sum of effect allele dosages × effect weights |
| `DENOM` | Number of non-missing genotypes used |
| `AVG` | `SUM / DENOM` (robust to missing genotypes) |

Load the results in R:

```r
data <- data.table::fread("results/bmi/score/aggregated_scores.txt")
data <- data |>
  dplyr::mutate(PGSID = sub("^(PGS[0-9]+).*", "\\1", PGS))
head(data)
```

## Monitoring

- Check SLURM job status: `squeue -u $USER`
- Follow the pipeline log: `tail -f results/bmi/pgs_calculation.log`
- Review the QC report after completion: `results/bmi/score/report.html`
  - Any score with fewer than `min_overlap` matching variants will appear as failed and will be excluded from `aggregated_scores.txt`

## Finding PGS IDs

1. Visit the [PGS Catalog](https://www.pgscatalog.org/)
2. Search for your trait or disease
3. Select a PGS based on population ancestry, number of variants, and publication

## Creating a Custom Scorefile

To use your own set of SNPs and weights, create a scorefile following the [pgsc_calc custom scoring guide](https://pgsc-calc.readthedocs.io/en/latest/how-to/calculate_custom.html) and provide the file path as the `--trait` argument.

## SLURM Resource Configuration

SLURM job resource limits (memory, CPUs, wall time per process) are defined in `pipeline/pgsc_calc.config`. Edit this file if you need to adjust limits for your cluster. If your cluster uses a different scheduler, change the `executor` field (e.g., `'lsf'`, `'pbs'`, `'local'`). See the [Nextflow executor docs](https://www.nextflow.io/docs/latest/executor.html).

## How PGS Are Calculated

The pipeline uses [`plink2 --score`](https://www.cog-genomics.org/plink/2.0/score):

```
PGS_i = Σ (dosage_ij × weight_j)
```

- `dosage_ij` — effect allele dosage for individual *i* at variant *j* (0–2 for imputed data)
- `weight_j` — effect weight (GWAS beta coefficient) for variant *j*

Key behaviours:
- **Missing genotypes**: mean-imputed using allele frequencies in the target sample; `DENOM` tracks how many non-missing genotypes were actually used
- **Allele matching**: by chromosome/position, allele codes (with strand flipping), or rsID
- **Ambiguous SNPs**: A/T and C/G SNPs without clear strand information may be excluded

## Note

Users should check whether their genotype data were used in the development of the PGS being scored, as this can lead to inflated estimates of PGS performance. See [Wray et al. (2014)](https://pmc.ncbi.nlm.nih.gov/articles/PMC4096801/).

## References

- PGS Catalog: <https://www.pgscatalog.org/>
- pgsc_calc pipeline: <https://github.com/PGScatalog/pgsc_calc>
- Cite the original study from which you obtained each PGS ID
