#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# RNA-MuTect Seven Bridges entrypoint
# ============================================================================

echo "============================================================"
echo " RNA-MuTect Docker container"
echo "============================================================"

echo ""
echo "Software versions:"
echo "------------------------------------------------------------"

echo "GATK:"
gatk --version || true

echo ""
echo "samtools:"
samtools --version | head -n 1 || true

echo ""
echo "HISAT2:"
hisat2 --version 2>&1 | head -n 1 || true

echo ""
echo "------------------------------------------------------------"

# -------------------------------------------------------------------------
# Make sure arguments were supplied
# -------------------------------------------------------------------------

if [[ "$#" -eq 0 ]]; then
    echo "ERROR: No arguments supplied."
    echo ""
    /opt/rna-mutect/pipeline.sh --help
    exit 1
fi

# -------------------------------------------------------------------------
# Find HISAT2 index directory or archive
# -------------------------------------------------------------------------

HISAT2_INDEX_DIR=""

ARGS=("$@")

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -h|--hisat2-index)

            if (( i + 1 >= ${#ARGS[@]} )); then
                echo "ERROR: Missing value after ${ARGS[$i]}"
                exit 1
            fi

            HISAT2_INDEX_DIR="${ARGS[$((i+1))]}"
            break
            ;;

    esac

done

if [[ -z "${HISAT2_INDEX_DIR}" ]]; then

    echo "ERROR: HISAT2 index directory or archive was not supplied."
    echo "Use:"
    echo "  -h <HISAT2_INDEX_DIRECTORY>"
    echo "or:"
    echo "  -h <HISAT2_INDEX_ARCHIVE.tar>"
    exit 1

fi

echo "HISAT2 index input:"
echo "  ${HISAT2_INDEX_DIR}"

# -------------------------------------------------------------------------
# If input is a TAR archive, extract it
# -------------------------------------------------------------------------

if [[ -f "${HISAT2_INDEX_DIR}" && "${HISAT2_INDEX_DIR}" == *.tar ]]; then

    echo ""
    echo "HISAT2 input is a TAR archive."
    echo "Extracting archive..."

    HISAT2_ARCHIVE="${HISAT2_INDEX_DIR}"

    # Create temporary extraction directory
    HISAT2_TMP_DIR="$(mktemp -d /tmp/hisat2_index.XXXXXX)"

    echo "Extraction directory:"
    echo "  ${HISAT2_TMP_DIR}"

    tar -xf "${HISAT2_ARCHIVE}" -C "${HISAT2_TMP_DIR}"

    # Find the directory containing the HISAT2 index files.
    # First look recursively for .1.ht2 / .1.ht2l files.
    mapfile -t INDEX_START_FILES < <(
        find "${HISAT2_TMP_DIR}" \
            -type f \
            \( -name "*.1.ht2" -o -name "*.1.ht2l" \) \
            | sort
    )

    if [[ "${#INDEX_START_FILES[@]}" -eq 0 ]]; then

        echo "ERROR: No HISAT2 index files found after extracting:"
        echo "  ${HISAT2_ARCHIVE}"
        echo ""
        echo "Extracted contents:"
        find "${HISAT2_TMP_DIR}" -maxdepth 3 -type f | head -50
        exit 1

    fi

    # Use the directory containing the index files
    HISAT2_INDEX_DIR="$(dirname "${INDEX_START_FILES[0]}")"

    echo ""
    echo "Extracted HISAT2 index directory:"
    echo "  ${HISAT2_INDEX_DIR}"

elif [[ ! -d "${HISAT2_INDEX_DIR}" ]]; then

    echo "ERROR: HISAT2 index input is neither a directory nor a .tar archive:"
    echo "  ${HISAT2_INDEX_DIR}"
    exit 1

fi

echo ""
echo "HISAT2 index directory:"
echo "  ${HISAT2_INDEX_DIR}"

# -------------------------------------------------------------------------
# Validate HISAT2 index directory
# -------------------------------------------------------------------------

if [[ ! -d "${HISAT2_INDEX_DIR}" ]]; then

    echo "ERROR: HISAT2 index is not a directory:"
    echo "  ${HISAT2_INDEX_DIR}"
    exit 1

fi

# -------------------------------------------------------------------------
# Locate HISAT2 index
#
# Standard index:
#
#   prefix.1.ht2
#   prefix.2.ht2
#   ...
#   prefix.8.ht2
#
# Large index:
#
#   prefix.1.ht2l
#   ...
#   prefix.8.ht2l
# -------------------------------------------------------------------------

mapfile -t HISAT2_INDEX_FILES < <(
    find "${HISAT2_INDEX_DIR}" \
        -maxdepth 1 \
        -type f \
        \( -name "*.1.ht2" -o -name "*.1.ht2l" \) \
        | sort
)

if [[ "${#HISAT2_INDEX_FILES[@]}" -ne 1 ]]; then

    echo "ERROR: Expected exactly one HISAT2 index."
    echo ""
    echo "Directory:"
    echo "  ${HISAT2_INDEX_DIR}"
    echo ""
    echo "Detected index starts:"
    printf '  %s\n' "${HISAT2_INDEX_FILES[@]}"
    echo ""
    echo "The directory should contain exactly one HISAT2 index."
    exit 1

fi

HISAT2_INDEX_FILE="${HISAT2_INDEX_FILES[0]}"

# Remove .1.ht2 or .1.ht2l

if [[ "${HISAT2_INDEX_FILE}" == *.1.ht2 ]]; then

    HISAT2_PREFIX="${HISAT2_INDEX_FILE%.1.ht2}"

else

    HISAT2_PREFIX="${HISAT2_INDEX_FILE%.1.ht2l}"

fi

echo ""
echo "Detected HISAT2 index:"
echo "  ${HISAT2_PREFIX}"

# -------------------------------------------------------------------------
# Validate the remaining HISAT2 index files
# -------------------------------------------------------------------------

if [[ "${HISAT2_INDEX_FILE}" == *.1.ht2 ]]; then

    for i in {1..8}; do

        if [[ ! -f "${HISAT2_PREFIX}.${i}.ht2" ]]; then

            echo "ERROR: Missing HISAT2 index file:"
            echo "  ${HISAT2_PREFIX}.${i}.ht2"
            exit 1

        fi

    done

else

    for i in {1..8}; do

        if [[ ! -f "${HISAT2_PREFIX}.${i}.ht2l" ]]; then

            echo "ERROR: Missing HISAT2 index file:"
            echo "  ${HISAT2_PREFIX}.${i}.ht2l"
            exit 1

        fi

    done

fi

echo "HISAT2 index validation: OK"

# -------------------------------------------------------------------------
# Replace the value following -h/--hisat2-index with the actual prefix
# -------------------------------------------------------------------------

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -h|--hisat2-index)

            ARGS[$((i+1))]="${HISAT2_PREFIX}"
            ;;

    esac

done

echo ""
echo "Starting RNA-MuTect pipeline..."
echo "============================================================"
echo ""

exec /opt/rna-mutect/pipeline.sh "${ARGS[@]}"
