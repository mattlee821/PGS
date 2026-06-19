#!/bin/bash
# ==============================================================================
# PGS-EPIC Setup Script
# Installs required tools (Java 21, Nextflow) into tools/ and creates
# params.yml from the example template.
# Logs to: logs/setup.log
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${REPO_ROOT}/tools"
LOGS_DIR="${REPO_ROOT}/logs"

mkdir -p "${TOOLS_DIR}" "${LOGS_DIR}"

LOG_FILE="${LOGS_DIR}/setup.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}=== $* ===${NC}"; }

OS="$(uname -s)"
ARCH="$(uname -m)"

header "PGS-EPIC Setup  |  $(date)"
echo "Repository root : ${REPO_ROOT}"
echo "OS              : ${OS} | ${ARCH}"
echo "Log             : ${LOG_FILE}"

# ------------------------------------------------------------------------------
# 1. Java
# ------------------------------------------------------------------------------
header "Checking Java..."

JAVA_INSTALL_DIR="${TOOLS_DIR}/java"
JAVA_MIN_VERSION=17

_java_major() {
    local bin="$1"
    local ver
    ver=$("${bin}" -version 2>&1 | awk -F '"' '/version/ {print $2}')
    if [[ "${ver}" == 1.* ]]; then
        echo "${ver}" | cut -d'.' -f2
    else
        echo "${ver}" | cut -d'.' -f1
    fi
}

JAVA_OK=false

if [[ -x "${JAVA_INSTALL_DIR}/bin/java" ]]; then
    ver=$(_java_major "${JAVA_INSTALL_DIR}/bin/java")
    if [[ "${ver}" -ge "${JAVA_MIN_VERSION}" ]]; then
        info "Java ${ver} already installed in tools/java — skipping."
        JAVA_OK=true
    fi
fi

if ! ${JAVA_OK} && command -v java &>/dev/null; then
    ver=$(_java_major "$(command -v java)")
    if [[ "${ver}" -ge "${JAVA_MIN_VERSION}" ]]; then
        info "Java ${ver} found in PATH — skipping install."
        JAVA_OK=true
    else
        warn "Java ${ver} found but version ${JAVA_MIN_VERSION}+ is required."
    fi
fi

if ! ${JAVA_OK}; then
    warn "Installing Java 21 (Adoptium/Eclipse Temurin) to tools/java..."

    case "${OS}" in
        Linux)  JDK_OS="linux" ;;
        Darwin) JDK_OS="mac" ;;
        *)      error "Unsupported OS: ${OS}. Install Java ${JAVA_MIN_VERSION}+ manually."; exit 1 ;;
    esac

    case "${ARCH}" in
        x86_64)        JDK_ARCH="x64" ;;
        aarch64|arm64) JDK_ARCH="aarch64" ;;
        *)             error "Unsupported arch: ${ARCH}. Install Java ${JAVA_MIN_VERSION}+ manually."; exit 1 ;;
    esac

    JDK_URL="https://api.adoptium.net/v3/binary/latest/21/ga/${JDK_OS}/${JDK_ARCH}/jdk/hotspot/normal/eclipse"
    TMP_JDK="${TOOLS_DIR}/jdk_download.tar.gz"

    info "Downloading JDK 21 from Adoptium..."
    curl -L --progress-bar -o "${TMP_JDK}" "${JDK_URL}"

    mkdir -p "${JAVA_INSTALL_DIR}"
    tar -xzf "${TMP_JDK}" -C "${JAVA_INSTALL_DIR}" --strip-components=1
    rm -f "${TMP_JDK}"

    info "Java 21 installed to tools/java"
fi

# ------------------------------------------------------------------------------
# 2. Nextflow
# ------------------------------------------------------------------------------
header "Checking Nextflow..."

NXF_BIN="${TOOLS_DIR}/nextflow"

if [[ -f "${NXF_BIN}" ]]; then
    info "Nextflow already installed in tools/ — skipping."
elif command -v nextflow &>/dev/null; then
    info "Nextflow found in PATH: $(nextflow -version 2>/dev/null | head -1 | xargs)"
else
    warn "Installing Nextflow to tools/nextflow..."
    (cd "${TOOLS_DIR}" && curl -fsSL https://get.nextflow.io | bash)
    chmod +x "${NXF_BIN}"
    info "Nextflow installed to tools/nextflow"
fi

# ------------------------------------------------------------------------------
# 3. Singularity / Apptainer
# ------------------------------------------------------------------------------
header "Checking Singularity/Apptainer..."

CONTAINER_MODULE=""

# Helper: try loading a module in the current shell without triggering set -eu
_try_module_load() {
    local mod="$1"
    set +eu
    module load "${mod}" 2>/dev/null
    set -eu
}

if command -v singularity &>/dev/null; then
    info "Singularity found in PATH: $(singularity --version 2>/dev/null | xargs)"
elif command -v apptainer &>/dev/null; then
    info "Apptainer found in PATH: $(apptainer --version 2>/dev/null | xargs)"
elif type module &>/dev/null 2>&1; then
    info "Container runtime not in PATH — searching module system..."
    for mod in apptainer singularity; do
        _try_module_load "${mod}"
        if command -v apptainer &>/dev/null || command -v singularity &>/dev/null; then
            CONTAINER_MODULE="${mod}"
            info "Module '${mod}' loaded and container runtime found."
            break
        fi
    done
    if [[ -z "${CONTAINER_MODULE}" ]]; then
        warn "Could not load a container module automatically."
        warn "Try: module avail apptainer  (or singularity) to find the right module name."
        warn "Then set container_module in params.yml and re-run setup."
    fi
else
    warn "Singularity/Apptainer not found and no module system detected."
    warn "Install guide: https://docs.sylabs.io/guides/latest/admin-guide/installation.html"
fi

# ------------------------------------------------------------------------------
# 4. params.yml
# ------------------------------------------------------------------------------
header "Configuring parameters..."

PARAMS_FILE="${REPO_ROOT}/params.yml"
PARAMS_EXAMPLE="${REPO_ROOT}/params.yml.example"

if [[ -f "${PARAMS_FILE}" ]]; then
    info "params.yml already exists — skipping creation."
    # Still update container_module if we just detected one and the file has it empty
    if [[ -n "${CONTAINER_MODULE}" ]]; then
        sed -i "s|^container_module:[[:space:]]*\"\"$|container_module: \"${CONTAINER_MODULE}\"|" "${PARAMS_FILE}"
        info "Updated container_module to '${CONTAINER_MODULE}' in existing params.yml"
    fi
else
    # Expand $HOME and inject detected container_module
    sed "s|\$HOME|${HOME}|g" "${PARAMS_EXAMPLE}" > "${PARAMS_FILE}"
    if [[ -n "${CONTAINER_MODULE}" ]]; then
        sed -i "s|^container_module:[[:space:]]*\"\"$|container_module: \"${CONTAINER_MODULE}\"|" "${PARAMS_FILE}"
    fi
    info "Created params.yml (paths expanded for ${HOME})"
fi

# Warn if required fields are still empty
MISSING=()
grep -q 'genetics_path:[[:space:]]*""' "${PARAMS_FILE}" && MISSING+=("genetics_path")
(grep -q 'container_module:[[:space:]]*""' "${PARAMS_FILE}" && \
 ! command -v singularity &>/dev/null && \
 ! command -v apptainer &>/dev/null) && MISSING+=("container_module")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}ACTION REQUIRED:${NC} Edit ~/PGS/params.yml before running the pipeline."
    echo ""
    echo "  Missing required values:"
    for field in "${MISSING[@]}"; do
        echo "    - ${field}"
    done
    echo ""
    echo "  File: ${PARAMS_FILE}"
fi

# ------------------------------------------------------------------------------
# Done
# ------------------------------------------------------------------------------
header "Setup complete!  |  $(date)"
echo ""
echo "Next: verify the pipeline works with the bundled test dataset:"
echo "  sbatch ~/PGS/src/run.sh --test"
echo ""
echo "Then run your analysis:"
echo "  sbatch ~/PGS/src/run.sh --trait PGS000717 --dir_out ~/PGS/analysis/bmi"
echo ""
echo "Override SLURM resources on the sbatch line:"
echo "  sbatch --time=48:00:00 --partition=compute \\"
echo "    ~/PGS/src/run.sh --trait PGS000717 --dir_out ~/PGS/analysis/bmi"
echo ""
