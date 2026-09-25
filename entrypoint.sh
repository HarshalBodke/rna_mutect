#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# RNA-MuTect Docker entrypoint
#
# Responsibilities
#   1. Print software versions
#   2. Accept HISAT2 TAR/TAR.GZ/TGZ archive or directory
#   3. Discover and validate the HISAT2 index prefix
#   4. Accept Funcotator TAR/TAR.GZ/TGZ archive or directory
#   5. Discover and validate the Funcotator data-source root
#   6. Normalize archive inputs to directories/prefixes
#   7. Pass normalized inputs to pipeline.sh
#
# The script deliberately does NOT depend on:
#   - a specific Seven Bridges project
#   - a specific sample name
#   - a specific Funcotator archive version
#   - a specific HISAT2 archive directory name
# =============================================================================


set +e
GATK_VERSION_OUTPUT="$(gatk --version 2>&1)"
GATK_STATUS=$?
set -e

echo "============================================================"
echo " RNA-MuTect Docker container"
echo "============================================================"

echo ""
echo "Software versions:"
echo "------------------------------------------------------------"

echo "GATK:"
if [[ ${GATK_STATUS} -eq 0 ]]; then
    echo "${GATK_VERSION_OUTPUT}"
else
    echo "${GATK_VERSION_OUTPUT}"
fi

echo ""
echo "samtools:"
samtools --version 2>&1 | head -n 1 || true

echo ""
echo "HISAT2:"
hisat2 --version 2>&1 | head -n 1 || true

echo ""
echo "------------------------------------------------------------"


# =============================================================================
# Utility functions
# =============================================================================

die() {
    echo ""
    echo "ERROR: $*" >&2
    exit 1
}


print_directory_tree() {

    local dir="$1"

    echo ""
    echo "Directory:"
    echo "  ${dir}"

    if [[ -d "${dir}" ]]; then
        find "${dir}" \
            -maxdepth 4 \
            -type d \
            | sort \
            | head -200
    fi
}


# =============================================================================
# Check arguments
# =============================================================================

if [[ "$#" -eq 0 ]]; then

    echo "ERROR: No arguments supplied."
    echo ""

    /opt/rna-mutect/pipeline.sh --help || true

    exit 1

fi


ARGS=("$@")


# =============================================================================
# Locate HISAT2 input
# =============================================================================

HISAT2_INPUT=""

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -h|--hisat2-index)

            (( i + 1 < ${#ARGS[@]} )) ||
                die "Missing value after ${ARGS[$i]}"

            HISAT2_INPUT="${ARGS[$((i+1))]}"

            break
            ;;

    esac

done


[[ -n "${HISAT2_INPUT}" ]] ||
    die "HISAT2 index input was not supplied. Use -h <archive-or-directory>."


echo ""
echo "HISAT2 index input:"
echo "  ${HISAT2_INPUT}"


# =============================================================================
# Locate Funcotator input
# =============================================================================

FUNCOTATOR_INPUT=""

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -f|--funcotator-sources)

            (( i + 1 < ${#ARGS[@]} )) ||
                die "Missing value after ${ARGS[$i]}"

            FUNCOTATOR_INPUT="${ARGS[$((i+1))]}"

            break
            ;;

    esac

done


[[ -n "${FUNCOTATOR_INPUT}" ]] ||
    die "Funcotator data sources input was not supplied. Use -f <archive-or-directory>."


echo ""
echo "Funcotator input:"
echo "  ${FUNCOTATOR_INPUT}"


# =============================================================================
# Temporary working directory
# =============================================================================

WORK_DIR="$(mktemp -d /tmp/rna-mutect.XXXXXX)"

echo ""
echo "Temporary working directory:"
echo "  ${WORK_DIR}"


cleanup() {

    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi

}

trap cleanup EXIT


# =============================================================================
# HISAT2 archive handling
# =============================================================================

HISAT2_INDEX_PREFIX=""
HISAT2_INDEX_EXTENSION=""
HISAT2_INDEX_FILE=""


if [[ -f "${HISAT2_INPUT}" ]]; then

    HISAT2_EXTRACT_DIR="${WORK_DIR}/hisat2"

    mkdir -p "${HISAT2_EXTRACT_DIR}"

    case "${HISAT2_INPUT}" in

        *.tar)

            echo ""
            echo "HISAT2 input detected as TAR archive."
            echo "Extracting..."

            tar -xf \
                "${HISAT2_INPUT}" \
                -C "${HISAT2_EXTRACT_DIR}"
            ;;


        *.tar.gz|*.tgz)

            echo ""
            echo "HISAT2 input detected as TAR.GZ/TGZ archive."
            echo "Extracting..."

            tar -xzf \
                "${HISAT2_INPUT}" \
                -C "${HISAT2_EXTRACT_DIR}"
            ;;


        *)

            die "HISAT2 file is not a supported archive: ${HISAT2_INPUT}"
            ;;

    esac

else

    [[ -d "${HISAT2_INPUT}" ]] ||
        die "HISAT2 input is neither a directory nor a supported archive: ${HISAT2_INPUT}"

    HISAT2_EXTRACT_DIR="${HISAT2_INPUT}"

fi


# =============================================================================
# Discover HISAT2 index
# =============================================================================

mapfile -t HISAT2_INDEX_START_FILES < <(
    find "${HISAT2_EXTRACT_DIR}" \
        -type f \
        \( \
            -name "*.1.ht2" \
            -o \
            -name "*.1.ht2l" \
        \) \
        | sort
)


if [[ "${#HISAT2_INDEX_START_FILES[@]}" -eq 0 ]]; then

    echo ""
    echo "ERROR: No HISAT2 index was found."

    print_directory_tree "${HISAT2_EXTRACT_DIR}"

    exit 1

fi


if [[ "${#HISAT2_INDEX_START_FILES[@]}" -ne 1 ]]; then

    echo ""
    echo "ERROR: Multiple HISAT2 indexes were found."

    printf '  %s\n' "${HISAT2_INDEX_START_FILES[@]}"

    exit 1

fi


HISAT2_INDEX_FILE="${HISAT2_INDEX_START_FILES[0]}"


if [[ "${HISAT2_INDEX_FILE}" == *.1.ht2 ]]; then

    HISAT2_INDEX_PREFIX="${HISAT2_INDEX_FILE%.1.ht2}"
    HISAT2_INDEX_EXTENSION="ht2"

else

    HISAT2_INDEX_PREFIX="${HISAT2_INDEX_FILE%.1.ht2l}"
    HISAT2_INDEX_EXTENSION="ht2l"

fi


echo ""
echo "Detected HISAT2 index prefix:"
echo "  ${HISAT2_INDEX_PREFIX}"


# =============================================================================
# Validate complete HISAT2 index
# =============================================================================

for i in {1..8}; do

    INDEX_FILE="${HISAT2_INDEX_PREFIX}.${i}.${HISAT2_INDEX_EXTENSION}"

    if [[ ! -f "${INDEX_FILE}" ]]; then

        die "Missing HISAT2 index file: ${INDEX_FILE}"
    fi

done


echo "HISAT2 index validation: OK"


# =============================================================================
# Funcotator archive handling
# =============================================================================

FUNCOTATOR_DATA_DIR=""


if [[ -f "${FUNCOTATOR_INPUT}" ]]; then

    FUNCOTATOR_EXTRACT_DIR="${WORK_DIR}/funcotator"

    mkdir -p "${FUNCOTATOR_EXTRACT_DIR}"

    case "${FUNCOTATOR_INPUT}" in

        *.tar.gz|*.tgz)

            echo ""
            echo "Funcotator input detected as TAR.GZ/TGZ archive."
            echo "Extracting..."

            tar -xzf \
                "${FUNCOTATOR_INPUT}" \
                -C "${FUNCOTATOR_EXTRACT_DIR}"
            ;;


        *.tar)

            echo ""
            echo "Funcotator input detected as TAR archive."
            echo "Extracting..."

            tar -xf \
                "${FUNCOTATOR_INPUT}" \
                -C "${FUNCOTATOR_EXTRACT_DIR}"
            ;;


        *)

            die "Funcotator file is not a supported archive: ${FUNCOTATOR_INPUT}"
            ;;

    esac

else

    [[ -d "${FUNCOTATOR_INPUT}" ]] ||
        die "Funcotator input is neither a directory nor a supported archive: ${FUNCOTATOR_INPUT}"

    FUNCOTATOR_EXTRACT_DIR="${FUNCOTATOR_INPUT}"

fi


# =============================================================================
# Discover Funcotator data-source root
#
# GATK Funcotator expects:
#
#   data-source-root/
#       source1/
#       source2/
#       source3/
#
# Your current archive has:
#
#   funcotator_dataSources.v1.8.hg38.20230908s/
#       gencode/
#       clinvar/
#       dbsnp/
#       ...
#
# Therefore the parent containing these source directories is the correct
# --data-sources-path.
# =============================================================================


# First preference:
# recognize conventional/versioned Funcotator directory names.

mapfile -t FUNCOTATOR_NAMED_CANDIDATES < <(
    find "${FUNCOTATOR_EXTRACT_DIR}" \
        -mindepth 1 \
        -maxdepth 3 \
        -type d \
        \( \
            -iname "dataSources" \
            -o \
            -iname "datasources" \
            -o \
            -iname "funcotator_dataSources*" \
            -o \
            -iname "funcotator_datasources*" \
        \) \
        | sort -u
)


if [[ "${#FUNCOTATOR_NAMED_CANDIDATES[@]}" -eq 1 ]]; then

    FUNCOTATOR_DATA_DIR="${FUNCOTATOR_NAMED_CANDIDATES[0]}"

fi


# =============================================================================
# Content-based fallback
#
# If the directory has an unexpected name, identify it by the presence of
# multiple recognizable Funcotator data-source directories.
# =============================================================================

if [[ -z "${FUNCOTATOR_DATA_DIR}" ]]; then

    mapfile -t FUNCOTATOR_CONTENT_CANDIDATES < <(
        find "${FUNCOTATOR_EXTRACT_DIR}" \
            -mindepth 1 \
            -type d \
            | sort -u
    )


    for candidate in "${FUNCOTATOR_CONTENT_CANDIDATES[@]}"; do

        source_count=0

        for source in \
            gencode \
            gencode_xrefseq \
            gencode_xhgnc \
            clinvar \
            clinvar_hgmd \
            dbsnp \
            hgnc \
            cosmic \
            cosmic_tissue \
            cosmic_fusion \
            oreganno \
            achilles \
            simple_uniprot \
            familial \
            dna_repair_genes
        do

            if [[ -d "${candidate}/${source}" ]]; then
                ((source_count+=1))
            fi

        done


        if (( source_count >= 3 )); then

            if [[ -n "${FUNCOTATOR_DATA_DIR}" ]]; then

                echo ""
                echo "ERROR: Multiple possible Funcotator data-source directories found:"
                echo "  ${FUNCOTATOR_DATA_DIR}"
                echo "  ${candidate}"

                exit 1

            fi

            FUNCOTATOR_DATA_DIR="${candidate}"

        fi

    done

fi


# =============================================================================
# Final Funcotator validation
# =============================================================================

if [[ -z "${FUNCOTATOR_DATA_DIR}" ]]; then

    echo ""
    echo "ERROR: Could not identify the Funcotator data-source directory."
    echo ""
    echo "Archive/input:"
    echo "  ${FUNCOTATOR_INPUT}"

    print_directory_tree "${FUNCOTATOR_EXTRACT_DIR}"

    exit 1

fi


[[ -d "${FUNCOTATOR_DATA_DIR}" ]] ||
    die "Detected Funcotator directory does not exist: ${FUNCOTATOR_DATA_DIR}"


# Count recognizable source directories.

FUNCOTATOR_SOURCE_COUNT=0

for source in \
    gencode \
    gencode_xrefseq \
    gencode_xhgnc \
    clinvar \
    clinvar_hgmd \
    dbsnp \
    hgnc \
    cosmic \
    cosmic_tissue \
    cosmic_fusion \
    oreganno \
    achilles \
    simple_uniprot \
    familial \
    dna_repair_genes
do

    if [[ -d "${FUNCOTATOR_DATA_DIR}/${source}" ]]; then
        ((FUNCOTATOR_SOURCE_COUNT+=1))
    fi

done


if (( FUNCOTATOR_SOURCE_COUNT < 3 )); then

    echo ""
    echo "ERROR: Detected directory does not appear to be a valid Funcotator"
    echo "data-source root:"
    echo ""
    echo "  ${FUNCOTATOR_DATA_DIR}"
    echo ""
    echo "Recognized data-source directories: ${FUNCOTATOR_SOURCE_COUNT}"

    exit 1

fi


echo ""
echo "Detected Funcotator data-source directory:"
echo "  ${FUNCOTATOR_DATA_DIR}"

echo "Funcotator data-source validation: OK"
echo "Recognized data-source directories: ${FUNCOTATOR_SOURCE_COUNT}"


# =============================================================================
# Normalize arguments
# =============================================================================

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -h|--hisat2-index)

            ARGS[$((i+1))]="${HISAT2_INDEX_PREFIX}"
            ;;


        -f|--funcotator-sources)

            ARGS[$((i+1))]="${FUNCOTATOR_DATA_DIR}"
            ;;

    esac

done


# =============================================================================
# Final normalized inputs
# =============================================================================

echo ""
echo "============================================================"
echo "Normalized pipeline inputs"
echo "============================================================"

echo ""
echo "HISAT2 index prefix:"
echo "  ${HISAT2_INDEX_PREFIX}"

echo ""
echo "Funcotator data sources:"
echo "  ${FUNCOTATOR_DATA_DIR}"


# =============================================================================
# Start pipeline
# =============================================================================

echo ""
echo "Starting RNA-MuTect pipeline..."
echo "============================================================"
echo ""


exec /opt/rna-mutect/pipeline.sh "${ARGS[@]}"
