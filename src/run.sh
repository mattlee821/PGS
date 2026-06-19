#!/bin/bash
# ==============================================================================
# PGS-EPIC Run Script
# Loads parameters from params.yml and runs the calculate_pgs pipeline.
# Invocation details are logged to: logs/run_<timestamp>.log
# Full pipeline output is logged to: <dir_out>/pgs_calculation.log
#
# Usage:
#   bash src/run.sh --trait <PGS_ID|scorefile> --dir_out <output_dir> [options]
#
# Options:
#   -t, --trait          PGS Catalog ID (e.g. PGS000717), comma-separated list,
#                        or path to a local scorefile
#   -o, --dir_out        Output directory for logs and results
#   -m, --min_overlap    Minimum variant overlap fraction (overrides params.yml)
#   -f, --filter_samples Path to a single-column file of sample IDs to keep
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PARAMS_FILE="${REPO_ROOT}/params.yml"
LOGS_DIR="${REPO_ROOT}/logs"

mkdir -p "${LOGS_DIR}"

# --- Validate params.yml exists ---
if [[ ! -f "${PARAMS_FILE}" ]]; then
    echo "Error: params.yml not found at ${PARAMS_FILE}" >&2
    echo "Run: bash src/setup.sh" >&2
    exit 1
fi

# --- YAML parser (handles key: value, key: "value", key: 'value') ---
# Also expands $HOME and leading ~ so users can write either form.
_yaml_get() {
    local key="$1"
    sed -n "s/^[[:space:]]*${key}[[:space:]]*:[[:space:]]*//p" "${PARAMS_FILE}" | \
        sed 's/[[:space:]]*#.*$//'             | \
        sed "s/^['\"]//; s/['\"]$//"          | \
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        sed "s|\$HOME|${HOME}|g; s|^~|${HOME}|" | \
        head -1
}

# --- Load parameters ---
GENETICS_PATH=$(_yaml_get "genetics_path")
SAMPLESET_NAME=$(_yaml_get "sampleset_name")
TARGET_BUILD=$(_yaml_get "target_build")
NXF_SINGULARITY_CACHEDIR=$(_yaml_get "singularity_cache")
PARAMS_MIN_OVERLAP=$(_yaml_get "min_overlap")

# --- Validate required parameters ---
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
export NXF_SINGULARITY_CACHEDIR
export PGSC_CONFIG="${REPO_ROOT}/pipeline/pgsc_calc.config"

# --- Set up Java and Nextflow from tools/ if present ---
if [[ -d "${REPO_ROOT}/tools/java" ]]; then
    export JAVA_HOME="${REPO_ROOT}/tools/java"
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
    export PATH="${JAVA_HOME}/bin:${REPO_ROOT}/tools:${PATH}"
else
    export PATH="${REPO_ROOT}/tools:${PATH}"
fi

# --- Build the argument list, applying params.yml defaults where not overridden ---
# We need to detect whether --min_overlap was passed explicitly on the CLI
EXTRA_ARGS=()
MIN_OVERLAP_IN_ARGS=false

for arg in "$@"; do
    if [[ "${arg}" == "-m" || "${arg}" == "--min_overlap" ]]; then
        MIN_OVERLAP_IN_ARGS=true
    fi
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
    echo "min_overlap       : ${PARAMS_MIN_OVERLAP:-0.75 (default)}"
    echo "cli args          : $*"
    echo ""
} | tee "${LOG_FILE}"

# --- Run the pipeline ---
source "${REPO_ROOT}/pipeline/PGS.sh"
calculate_pgs "${EXTRA_ARGS[@]}" "$@"
