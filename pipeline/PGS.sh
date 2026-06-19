#!/bin/bash
# ==============================================================================
# Function: calculate_pgs
# Description: Executes the pgscatalog/pgsc_calc Nextflow pipeline to compute
#              Polygenic Scores using either Catalog IDs or local scorefiles.
#
# Named Arguments:
#   -t, --trait        REQUIRED. A single PGS ID (e.g., "PGS003850"), a
#                        comma-separated list, or a path to a local scorefile.
#   -o, --dir_out        REQUIRED. Path to the output directory for logs,
#                        work files, and final results.
#   -m, --min_overlap    OPTIONAL. Minimum variant overlap threshold (0-1).
#                        Default is 0.75.
#   -f, --filter_samples OPTIONAL. Path to a headerless, single-column text
#                        file of sample IDs to retain for analysis.
#
# Required environment variables (set via config/site.conf):
#   GENETICS_PATH        Prefix path to PLINK binary files (.bed/.bim/.fam)
#   NXF_SINGULARITY_CACHEDIR  Directory for Singularity image cache
#   PGSC_CONFIG          Path to the pgsc_calc Nextflow config file
#
# Features:
#   - Automatically sanitizes local scorefiles by removing commas from positions.
#   - Detects and strips headers from sample filter files.
#   - Reformats final output: renames IID to ID_sample and removes FID/sampleset.
#   - Filters final results based on provided sample IDs if --filter_samples is used.
# ==============================================================================
calculate_pgs() {
    # Initialize local variables with defaults
    local trait=""
    local dir_out=""
    local min_overlap="0.75"
    local filter_samples=""
    local pgs_input_flag=""
    local filter_flag=""

    # --- 1. ARGUMENT PARSING ---
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--trait)
                trait="$2"
                shift 2
                ;;
            -o|--dir_out)
                dir_out="$2"
                shift 2
                ;;
            -m|--min_overlap)
                min_overlap="$2"
                shift 2
                ;;
            -f|--filter_samples)
                filter_samples="$2"
                shift 2
                ;;
            *)
                echo "Error: Unknown parameter '$1'" >&2
                return 1
                ;;
        esac
    done

    # --- 2. VALIDATION ---
    if [[ -z "${trait}" || -z "${dir_out}" ]]; then
        echo "Error: --trait and --dir_out are required arguments." >&2
        return 1
    fi

    if [[ -z "${GENETICS_PATH}" ]]; then
        echo "Error: GENETICS_PATH is not set. Please configure config/site.conf." >&2
        return 1
    fi

    if [[ -z "${PGSC_CONFIG}" || ! -f "${PGSC_CONFIG}" ]]; then
        echo "Error: PGSC_CONFIG is not set or does not exist: '${PGSC_CONFIG}'" >&2
        return 1
    fi

    # Check if trait is a local file or a Catalog ID
    if [[ -f "${trait}" ]]; then
        local abs_scorefile
        abs_scorefile=$(realpath "${trait}")
        echo "Info: Local scorefile detected. Cleaning formatting..."

        # A. Remove Windows carriage returns and fix numeric commas
        sed -i 's/\r//g' "${abs_scorefile}"
        sed -i 's/\([0-9]\),\([0-9]\)/\1\2/g' "${abs_scorefile}"

        # B. Remove rows where effect_weight is "-"
        awk -F'\t' '
            BEGIN { OFS="\t"; col=0; count=0 }
            /^#/ { print $0; next }
            col == 0 {
                for (i=1; i<=NF; i++) {
                    if ($i == "effect_weight") col=i
                }
                print $0; next
            }
            {
                if (col > 0 && $col == "-") {
                    count++
                } else {
                    print $0
                }
            }
            END {
                if (count > 0) {
                    system("echo \"Summary: Removed " count " variants with missing weights (-)\" >&2")
                }
            }
        ' "${abs_scorefile}" > "${abs_scorefile}.tmp" && mv "${abs_scorefile}.tmp" "${abs_scorefile}"

        pgs_input_flag="--scorefile ${abs_scorefile}"
    else
        echo "Info: Using PGS Catalog ID(s): ${trait}"
        pgs_input_flag="--pgs_id ${trait}"
    fi

    # Check and sanitize filter file (Absolute Path check)
    local abs_filter=""
    if [[ -n "${filter_samples}" ]]; then
        if [[ -f "${filter_samples}" ]]; then
            abs_filter=$(realpath "${filter_samples}")
            # Ensure no header in the filter file for easier AWK processing later
            if head -n 1 "$abs_filter" | grep -qiE "ID|sample|IID|FID"; then
                echo "Info: Header detected in filter file. Removing first line..."
                sed -i '1d' "$abs_filter"
            fi
        else
            echo "Error: Filter file '${filter_samples}' not found." >&2
            return 1
        fi
    fi

    # --- 3. ENVIRONMENT & SETUP ---
    local start_time=$(date +%s)
    mkdir -p "${dir_out}"
    local work_dir="${dir_out}/work"
    mkdir -p "${work_dir}"

    local SAMPLESHEET_FILE="${work_dir}/samplesheet.csv"
    local log_file="${dir_out}/pgs_calculation.log"

    exec > >(tee -a "${log_file}") 2>&1

    # --- 4. SAMPLESHEET ---
    echo "## Creating samplesheet..."
    local sampleset_name="${SAMPLESET_NAME:-combined}"
    echo "sampleset,path_prefix,chrom,format" > "${SAMPLESHEET_FILE}"
    echo "${sampleset_name},${GENETICS_PATH},,bfile" >> "${SAMPLESHEET_FILE}"

    # --- 5. EXECUTION ---
    cd "${work_dir}"

    nextflow run pgscatalog/pgsc_calc \
        -profile "singularity" \
        -config "${PGSC_CONFIG}" \
        --input "${SAMPLESHEET_FILE}" \
        ${pgs_input_flag} \
        --target_build "${TARGET_BUILD:-GRCh37}" \
        --min_overlap "${min_overlap}" \
        --outdir "${work_dir}/results"

    local nxf_status=$?
    if [[ ${nxf_status} -ne 0 ]]; then
        echo "Error: Nextflow pipeline failed." >&2
        return 1
    fi

    # --- 6. POST-PROCESSING (Reformatting & Filtering) ---
    echo "## Reformatting and filtering final scores..."

    local src_score_dir="${work_dir}/results/${sampleset_name}/score"
    local score_dir="${dir_out}/score"

    if [[ -d "${src_score_dir}" ]]; then
        rm -rf "${score_dir}"
        cp -r "${src_score_dir}" "${score_dir}"
        rm -f "${score_dir}/versions.yml"

        local score_file_gz="${score_dir}/aggregated_scores.txt.gz"
        local score_file_txt="${score_dir}/aggregated_scores.txt"

        if [[ -f "${score_file_gz}" ]]; then
            echo "### Processing ${score_file_gz} to flat text..."

            # Use AWK to filter by sample ID and reformat columns simultaneously
            zcat "${score_file_gz}" | \
                awk -v filter_file="${abs_filter}" 'BEGIN {
                    FS="\t"; OFS="\t"
                    # Load filter IDs into an array if the file exists
                    if (filter_file != "") {
                        while ((getline < filter_file) > 0) {
                            keep[$1] = 1
                        }
                        close(filter_file)
                    }
                }
                NR==1 {
                    # Identify IID index (Column 1 is usually IID in pgsc_calc output)
                    for(i=1; i<=NF; i++) {
                        if($i=="IID") {
                            iid_col=i
                            $i="ID_sample"
                        }
                        if($i!="sampleset" && $i!="FID") {
                            cols[++n]=i
                        }
                    }
                    # Print Header
                    for(i=1; i<=n; i++) printf "%s%s", $(cols[i]), (i<n ? OFS : "\n")
                    next
                }
                {
                    # Filter: If filter_file was provided, check if IID is in our "keep" array
                    if (length(keep) > 0 && !( $(iid_col) in keep )) {
                        next
                    }
                    # Reformat: Print selected columns
                    for(i=1; i<=n; i++) {
                        printf "%s%s", $(cols[i]), (i<n ? OFS : "\n")
                    }
                }' > "${score_file_txt}"

            rm -f "${score_file_gz}"
            echo "### Success: Output saved to ${score_file_txt}"
            if [[ -n "${abs_filter}" ]]; then
                echo "### Info: Applied sample filtering from $(basename "${abs_filter}")"
            fi
        else
            echo "### WARNING: File ${score_file_gz} does not exist."
        fi
    else
        echo "### WARNING: Directory ${src_score_dir} does not exist."
    fi

    echo "------------------------------------------------------"
    echo "# DONE: Total Runtime: $(($(date +%s) - start_time)) seconds"
    echo "------------------------------------------------------"

    return 0
}
