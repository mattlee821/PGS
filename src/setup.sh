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

if command -v singularity &>/dev/null; then
    info "Singularity found: $(singularity --version 2>/dev/null | xargs)"
elif command -v apptainer &>/dev/null; then
    info "Apptainer found: $(apptainer --version 2>/dev/null | xargs)"
else
    warn "Singularity/Apptainer not found in PATH."
    warn "pgsc_calc requires Singularity or Apptainer to run containers."
    warn "On HPC: try 'module load singularity' or 'module load apptainer'"
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
else
    # Expand $HOME so the written file contains the real path
    sed "s|\$HOME|${HOME}|g" "${PARAMS_EXAMPLE}" > "${PARAMS_FILE}"
    info "Created params.yml (paths expanded for ${HOME})"
fi

# Warn if required fields are still empty
MISSING=()
grep -q 'genetics_path:[[:space:]]*""' "${PARAMS_FILE}"  && MISSING+=("genetics_path")

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}ACTION REQUIRED:${NC} Edit params.yml before running the pipeline."
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
echo "Usage:"
echo "  bash src/run.sh --trait PGS000717 --dir_out /path/to/output"
echo ""
echo "To submit as a SLURM job:"
echo "  #!/bin/bash"
echo "  #SBATCH --job-name=pgs --ntasks=1 --mem=4G --time=10:00:00"
echo "  bash /path/to/PGS-EPIC/src/run.sh --trait PGS000717 --dir_out /path/to/output"
echo ""
