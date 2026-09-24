#!/usr/bin/env bash

set -euo pipefail

# ============================================================================
# RNA-MuTect Seven Bridges entrypoint
#
# Responsibilities:
#   1. Print software versions
#   2. Accept HISAT2 TAR archive or directory
#   3. Accept Funcotator TAR/TAR.GZ archive or directory
#   4. Extract archives when necessary
#   5. Discover the actual HISAT2 index prefix
#   6. Discover the Funcotator data-source directory
#   7. Pass normalized inputs to pipeline.sh
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


# ============================================================================
# Make sure arguments were supplied
# ============================================================================

if [[ "$#" -eq 0 ]]; then

    echo "ERROR: No arguments supplied."
    echo ""

    /opt/rna-mutect/pipeline.sh --help

    exit 1

fi


# ============================================================================
# Preserve original arguments
# ============================================================================

ARGS=("$@")


# ============================================================================
# Locate HISAT2 input
# ============================================================================

HISAT2_INPUT=""

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -h|--hisat2-index)

            if (( i + 1 >= ${#ARGS[@]} )); then

                echo "ERROR: Missing value after ${ARGS[$i]}"
                exit 1

            fi

            HISAT2_INPUT="${ARGS[$((i+1))]}"

            break
            ;;

    esac

done


if [[ -z "${HISAT2_INPUT}" ]]; then

    echo "ERROR: HISAT2 index input was not supplied."
    echo ""
    echo "Use:"
    echo "  -h <HISAT2_INDEX.tar>"
    echo "or:"
    echo "  -h <HISAT2_INDEX_DIRECTORY>"

    exit 1

fi


echo ""
echo "HISAT2 index input:"
echo "  ${HISAT2_INPUT}"


# ============================================================================
# Locate Funcotator input
# ============================================================================

FUNCOTATOR_INPUT=""

for ((i=0; i<${#ARGS[@]}; i++)); do

    case "${ARGS[$i]}" in

        -f|--funcotator-sources)

            if (( i + 1 >= ${#ARGS[@]} )); then

                echo "ERROR: Missing value after ${ARGS[$i]}"
                exit 1

            fi

            FUNCOTATOR_INPUT="${ARGS[$((i+1))]}"

            break
            ;;

    esac

done


if [[ -z "${FUNCOTATOR_INPUT}" ]]; then

    echo "ERROR: Funcotator data sources input was not supplied."
    echo ""
    echo "Use:"
    echo "  -f <FUNCOTATOR_SOURCES.tar.gz>"
    echo "or:"
    echo "  -f <FUNCOTATOR_SOURCES_DIRECTORY>"

    exit 1

fi


echo ""
echo "Funcotator input:"
echo "  ${FUNCOTATOR_INPUT}"


# ============================================================================
# Temporary working directory
# ============================================================================

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


# ============================================================================
# HISAT2 archive handling
# ============================================================================

HISAT2_INDEX_PREFIX=""


if [[ -f "${HISAT2_INPUT}" ]]; then

    case "${HISAT2_INPUT}" in

        *.tar)

            echo ""
            echo "HISAT2 input detected as TAR archive."
            echo "Extracting..."

            HISAT2_EXTRACT_DIR="${WORK_DIR}/hisat2"

            mkdir -p "${HISAT2_EXTRACT_DIR}"

            tar -xf \
                "${HISAT2_INPUT}" \
                -C "${HISAT2_EXTRACT_DIR}"

            ;;


        *.tar.gz|*.tgz)

            echo ""
            echo "HISAT2 input detected as TAR.GZ archive."
            echo "Extracting..."

            HISAT2_EXTRACT_DIR="${WORK_DIR}/hisat2"

            mkdir -p "${HISAT2_EXTRACT_DIR}"

            tar -xzf \
                "${HISAT2_INPUT}" \
                -C "${HISAT2_EXTRACT_DIR}"

            ;;


        *)

            echo "ERROR: HISAT2 file is not a supported archive:"
            echo "  ${HISAT2_INPUT}"
            echo ""
            echo "Supported:"
            echo "  .tar"
            echo "  .tar.gz"
            echo "  .tgz"

            exit 1

            ;;

    esac


    # ------------------------------------------------------------------------
    # Find HISAT2 index start files recursively
    # ------------------------------------------------------------------------

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
        echo "ERROR: No HISAT2 index files were found after extraction."
        echo ""
        echo "Archive:"
        echo "  ${HISAT2_INPUT}"
        echo ""
        echo "Extracted contents:"
        find "${HISAT2_EXTRACT_DIR}" \
            -maxdepth 4 \
            -type f \
            | head -100

        exit 1

    fi


    if [[ "${#HISAT2_INDEX_START_FILES[@]}" -ne 1 ]]; then

        echo ""
        echo "ERROR: Multiple HISAT2 indexes were found in the archive."
        echo ""
        echo "Detected index starts:"

        printf '  %s\n' "${HISAT2_INDEX_START_FILES[@]}"

        echo ""
        echo "The archive must contain exactly one HISAT2 index."

        exit 1

    fi


    HISAT2_INDEX_FILE="${HISAT2_INDEX_START_FILES[0]}"


else

    # ------------------------------------------------------------------------
    # HISAT2 input is already a directory
    # ------------------------------------------------------------------------

    if [[ ! -d "${HISAT2_INPUT}" ]]; then

        echo ""
        echo "ERROR: HISAT2 input is neither a directory nor a supported archive:"
        echo "  ${HISAT2_INPUT}"

        exit 1

    fi


    HISAT2_EXTRACT_DIR="${HISAT2_INPUT}"


    mapfile -t HISAT2_INDEX_START_FILES < <(
        find "${HISAT2_EXTRACT_DIR}" \
            -maxdepth 1 \
            -type f \
            \( \
                -name "*.1.ht2" \
                -o \
                -name "*.1.ht2l" \
            \) \
            | sort
    )


    if [[ "${#HISAT2_INDEX_START_FILES[@]}" -ne 1 ]]; then

        echo ""
        echo "ERROR: Expected exactly one HISAT2 index."

        echo ""
        echo "Directory:"
        echo "  ${HISAT2_EXTRACT_DIR}"

        echo ""
        echo "Detected index starts:"

        printf '  %s\n' "${HISAT2_INDEX_START_FILES[@]}"

        exit 1

    fi


    HISAT2_INDEX_FILE="${HISAT2_INDEX_START_FILES[0]}"

fi


# ============================================================================
# Determine HISAT2 prefix
# ============================================================================

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


# ============================================================================
# Validate all HISAT2 index files
# ============================================================================

for i in {1..8}; do

    INDEX_FILE="${HISAT2_INDEX_PREFIX}.${i}.${HISAT2_INDEX_EXTENSION}"

    if [[ ! -f "${INDEX_FILE}" ]]; then

        echo ""
        echo "ERROR: Missing HISAT2 index file:"
        echo "  ${INDEX_FILE}"

        exit 1

    fi

done


echo "HISAT2 index validation: OK"


# ============================================================================
# Funcotator archive handling
# ============================================================================

FUNCOTATOR_DATA_DIR=""


if [[ -f "${FUNCOTATOR_INPUT}" ]]; then

    case "${FUNCOTATOR_INPUT}" in

        *.tar.gz|*.tgz)

            echo ""
            echo "Funcotator input detected as TAR.GZ archive."
            echo "Extracting..."

            FUNCOTATOR_EXTRACT_DIR="${WORK_DIR}/funcotator"

            mkdir -p "${FUNCOTATOR_EXTRACT_DIR}"

            tar -xzf \
                "${FUNCOTATOR_INPUT}" \
                -C "${FUNCOTATOR_EXTRACT_DIR}"

            ;;


        *.tar)

            echo ""
            echo "Funcotator input detected as TAR archive."
            echo "Extracting..."

            FUNCOTATOR_EXTRACT_DIR="${WORK_DIR}/funcotator"

            mkdir -p "${FUNCOTATOR_EXTRACT_DIR}"

            tar -xf \
                "${FUNCOTATOR_INPUT}" \
                -C "${FUNCOTATOR_EXTRACT_DIR}"

            ;;


        *)

            echo ""
            echo "ERROR: Funcotator file is not a supported archive:"
            echo "  ${FUNCOTATOR_INPUT}"
            echo ""
            echo "Supported:"
            echo "  .tar"
            echo "  .tar.gz"
            echo "  .tgz"

            exit 1

            ;;

    esac


    # ------------------------------------------------------------------------
    # Find Funcotator data-source directory
    #
    # Funcotator data sources normally contain files such as:
    #
    #   dataSources/
    #   datasources/
    #
    # We first search for a directory containing _multiple_ source
    # directories/files rather than blindly selecting the first directory.
    # ------------------------------------------------------------------------

    mapfile -t FUNCOTATOR_CANDIDATES < <(
        find "${FUNCOTATOR_EXTRACT_DIR}" \
            -type f \
            \( \
                -name "dataSource.version" \
                -o \
                -name "reference-version.txt" \
            \) \
            -printf '%h\n' \
            | sort -u
    )


    if [[ "${#FUNCOTATOR_CANDIDATES[@]}" -eq 1 ]]; then

        FUNCOTATOR_DATA_DIR="${FUNCOTATOR_CANDIDATES[0]}"

    else

        # --------------------------------------------------------------------
        # Fallback:
        # Search directories named dataSources or datasources.
        # --------------------------------------------------------------------

        mapfile -t FUNCOTATOR_DIR_CANDIDATES < <(
            find "${FUNCOTATOR_EXTRACT_DIR}" \
                -type d \
                \( \
                    -iname "dataSources" \
                    -o \
                    -iname "datasources" \
                \) \
                | sort
        )


        if [[ "${#FUNCOTATOR_DIR_CANDIDATES[@]}" -eq 1 ]]; then

            FUNCOTATOR_DATA_DIR="${FUNCOTATOR_DIR_CANDIDATES[0]}"

        fi

    fi


    if [[ -z "${FUNCOTATOR_DATA_DIR}" ]]; then

        echo ""
        echo "ERROR: Could not identify the Funcotator data-source directory."
        echo ""
        echo "Archive:"
        echo "  ${FUNCOTATOR_INPUT}"
        echo ""
        echo "Extracted directories:"
        find "${FUNCOTATOR_EXTRACT_DIR}" \
            -maxdepth 4 \
            -type d \
            | head -100

        exit 1

    fi


else

    # ------------------------------------------------------------------------
    # Funcotator input is already a directory
    # ------------------------------------------------------------------------

    if [[ ! -d "${FUNCOTATOR_INPUT}" ]]; then

        echo ""
        echo "ERROR: Funcotator input is neither a directory nor a supported archive:"
        echo "  ${FUNCOTATOR_INPUT}"

        exit 1

    fi


    FUNCOTATOR_DATA_DIR="${FUNCOTATOR_INPUT}"

fi


# ============================================================================
# Validate Funcotator directory
# ============================================================================

if [[ ! -d "${FUNCOTATOR_DATA_DIR}" ]]; then

    echo ""
    echo "ERROR: Funcotator data-source directory does not exist:"
    echo "  ${FUNCOTATOR_DATA_DIR}"

    exit 1

fi


echo ""
echo "Detected Funcotator data-source directory:"
echo "  ${FUNCOTATOR_DATA_DIR}"


# ============================================================================
# Replace archive inputs with normalized paths
# ============================================================================

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


# ============================================================================
# Print final normalized inputs
# ============================================================================

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


# ============================================================================
# Start pipeline
# ============================================================================

echo ""
echo "Starting RNA-MuTect pipeline..."
echo "============================================================"
echo ""


exec /opt/rna-mutect/pipeline.sh "${ARGS[@]}"
