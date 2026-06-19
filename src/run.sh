#!/bin/bash
#SBATCH --job-name=pgs
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=1-00:00:00
#SBATCH --mem=4G
#SBATCH --account=sscm015962
#SBATCH --output=logs/%x-%j.out
#SBATCH --error=logs/%x-%j.err
# ==============================================================================
# PGS-EPIC Run Script
# Loads parameters from params.yml and runs the calculate_pgs pipeline.
# Invocation details are logged to: ~/PGS/logs/run_<timestamp>.log
# Full pipeline output is logged to: <dir_out>/pgs_calculation.log
#
# Interactive:  bash ~/PGS/src/run.sh --trait <PGS_ID|scorefile> --dir_out <path>
#               bash ~/PGS/src/run.sh --test
# SLURM job:    sbatch ~/PGS/src/run.sh --trait <PGS_ID|scorefile> --dir_out <path>
#               sbatch ~/PGS/src/run.sh --test
# Override resources on the command line:
#               sbatch --time=48:00:00 --mem=8G ~/PGS/src/run.sh --trait ...
#
# Options:
#   --test               Run the pgsc_calc test profile; output goes to ~/PGS/test/
#   -t, --trait          PGS Catalog ID (e.g. PGS000717), comma-separated list,
#                        or path to a local scorefile
#   -o, --dir_out        Output directory for logs and results
#   -m, --min_overlap    Minimum variant overlap fraction (overrides params.yml)
#   -f, --filter_samples Path to a single-column file of sample IDs to keep
# ==============================================================================
set -euo pipefail

# --- Initialize module system for non-interactive SLURM jobs ---
if ! type module &>/dev/null 2>&1; then
    for _mod_init in \
        /etc/profile.d/lmod.sh \
        /etc/profile.d/modules.sh \
        /usr/share/lmod/lmod/init/bash \
        /usr/share/modules/init/bash \
        /usr/local/Modules/init/bash; do
        if [[ -f "${_mod_init}" ]]; then
            set +eu
            source "${_mod_init}"
            set -eu
            break
        fi
    done
fi

if [[ -n "${SLURM_SUBMIT_DIR:-}" ]]; then
    REPO_ROOT="${SLURM_SUBMIT_DIR}"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
PARAMS_FILE="${REPO_ROOT}/params.yml"
LOGS_DIR="${REPO_ROOT}/logs"

mkdir -p "${LOGS_DIR}"

# --- Validate params.yml exists ---
if [[ ! -f "${PARAMS_FILE}" ]]; then
    echo "Error: params.yml not found at ${PARAMS_FILE}" >&2
    echo "Run: bash ~/PGS/src/setup.sh" >&2
    exit 1
fi

# --- YAML parser (handles key: value, key: "value", key: 'value') ---
# Expands $HOME and leading ~ in values.
_yaml_get() {
    local key="$1"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//p" "${PARAMS_FILE}" | \
        sed 's/[[:space:]]*#.*$//'             | \
        sed "s/^['\"]//; s/['\"]$//"          | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        sed "s|\$HOME|${HOME}|g; s|^~|${HOME}|" | \
        head -1
}

# --- Load all parameters ---
GENETICS_PATH=$(_yaml_get "genetics_path")
SAMPLESET_NAME=$(_yaml_get "sampleset_name")
TARGET_BUILD=$(_yaml_get "target_build")
NXF_SINGULARITY_CACHEDIR=$(_yaml_get "singularity_cache")
PARAMS_MIN_OVERLAP=$(_yaml_get "min_overlap")
CONTAINER_MODULE=$(_yaml_get "container_module")

# --- Set up Java from tools/ if present ---
if [[ -d "${REPO_ROOT}/tools/java" ]]; then
    export JAVA_HOME="${REPO_ROOT}/tools/java"
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
    export PATH="${JAVA_HOME}/bin:${REPO_ROOT}/tools:${PATH}"
else
    export PATH="${REPO_ROOT}/tools:${PATH}"
fi

export PGSC_CONFIG="${REPO_ROOT}/pipeline/pgsc_calc.config"
export NXF_SINGULARITY_CACHEDIR

# --- Load container module if specified ---
if [[ -n "${CONTAINER_MODULE}" ]]; then
    if type module &>/dev/null 2>&1; then
        set +eu
        module load "${CONTAINER_MODULE}" 2>/dev/null
        set -eu
    else
        echo "Warning: container_module '${CONTAINER_MODULE}' set but no module system found." >&2
    fi
fi

# --- Determine Nextflow container profile ---
if command -v singularity &>/dev/null; then
    export CONTAINER_PROFILE="singularity"
elif command -v apptainer &>/dev/null; then
    export CONTAINER_PROFILE="apptainer"
else
    echo "Error: Neither singularity nor apptainer found after loading module '${CONTAINER_MODULE}'." >&2
    echo "Set container_module in params.yml to the correct module name." >&2
    exit 1
fi

# --- Handle --test flag ---
if [[ "${1:-}" == "--test" ]]; then
    TEST_DIR="${REPO_ROOT}/test"
    mkdir -p "${TEST_DIR}"
    LOG_FILE="${TEST_DIR}/test.log"

    {
        echo "=== PGS-EPIC Test Run: $(date) ==="
        echo "Container profile : ${CONTAINER_PROFILE}"
        echo "Config            : ${PGSC_CONFIG}"
        echo "Output            : ${TEST_DIR}/results"
        echo ""
    } | tee "${LOG_FILE}"

    cd "${TEST_DIR}"
    nextflow run pgscatalog/pgsc_calc \
        -profile "test,${CONTAINER_PROFILE}" \
        -config "${PGSC_CONFIG}" \
        --outdir "${TEST_DIR}/results" \
        2>&1 | tee -a "${LOG_FILE}"
    NXF_STATUS=${PIPESTATUS[0]}
    cd "${REPO_ROOT}"

    echo "" | tee -a "${LOG_FILE}"
    if [[ ${NXF_STATUS} -eq 0 ]]; then
        echo "=== Test PASSED ===" | tee -a "${LOG_FILE}"
        echo "Results: ${TEST_DIR}/results"
    else
        echo "=== Test FAILED — see ${LOG_FILE} ===" | tee -a "${LOG_FILE}"
        exit 1
    fi
    exit 0
fi

# --- Validate required parameters for a real run ---
if [[ -z "${GENETICS_PATH}" ]]; then
    echo "Error: 'genetics_path' is not set in params.yml." >&2
    exit 1
fi
if [[ -z "${NXF_SINGULARITY_CACHEDIR}" ]]; then
    echo "Error: 'singularity_cache' is not set in params.yml." >&2
    exit 1
fi

# --- Export environment for pipeline/PGS.sh ---
export GENETICS_PATH
export SAMPLESET_NAME="${SAMPLESET_NAME:-combined}"
export TARGET_BUILD="${TARGET_BUILD:-GRCh37}"

# --- Apply params.yml min_overlap unless overridden on the CLI ---
EXTRA_ARGS=()
MIN_OVERLAP_IN_ARGS=false
for arg in "$@"; do
    [[ "${arg}" == "-m" || "${arg}" == "--min_overlap" ]] && MIN_OVERLAP_IN_ARGS=true
done
if ! ${MIN_OVERLAP_IN_ARGS} && [[ -n "${PARAMS_MIN_OVERLAP}" ]]; then
    EXTRA_ARGS+=("--min_overlap" "${PARAMS_MIN_OVERLAP}")
fi

# --- Log invocation record ---
LOG_FILE="${LOGS_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
{
    echo "=== PGS-EPIC Run: $(date) ==="
    echo "params.yml        : ${PARAMS_FILE}"
    echo "genetics_path     : ${GENETICS_PATH}"
    echo "sampleset_name    : ${SAMPLESET_NAME}"
    echo "target_build      : ${TARGET_BUILD}"
    echo "singularity_cache : ${NXF_SINGULARITY_CACHEDIR}"
    echo "container_profile : ${CONTAINER_PROFILE}"
    echo "min_overlap       : ${PARAMS_MIN_OVERLAP:-0.75 (default)}"
    echo "cli args          : $*"
    echo ""
} | tee "${LOG_FILE}"

# --- Run the pipeline ---
source "${REPO_ROOT}/pipeline/PGS.sh"
calculate_pgs "${EXTRA_ARGS[@]}" "$@"
