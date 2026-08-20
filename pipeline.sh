#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# Modern RNA-MuTect Pipeline
# GATK4 + HISAT2
#
# Seven Bridges / Docker version
# =============================================================================

usage() {

    echo ""
    echo "Usage:"
    echo "  $0 -r <RNA_BAM> [-n <NORMAL_DNA_BAM> -s <NORMAL_SAMPLE_NAME>] \\"
    echo "     -g <GENOME_FASTA> \\"
    echo "     -p <PANEL_OF_NORMALS> \\"
    echo "     -a <GERMLINE_RESOURCE> \\"
    echo "     -f <FUNCOTATOR_SOURCES> \\"
    echo "     -h <HISAT2_INDEX> \\"
    echo "     -o <OUTPUT_DIR> [-t <THREADS>]"
    echo ""

    echo "Required:"
    echo "  -r, --rna-bam"
    echo "      Input STAR-aligned RNA BAM."
    echo ""
    echo "  -g, --genome-fasta"
    echo "      GRCh38 reference FASTA."
    echo ""
    echo "  -p, --pon"
    echo "      Panel of Normals VCF."
    echo ""
    echo "  -a, --germline-resource"
    echo "      Germline resource VCF."
    echo ""
    echo "  -f, --funcotator-sources"
    echo "      Funcotator data sources directory."
    echo ""
    echo "  -h, --hisat2-index"
    echo "      HISAT2 index directory/prefix."
    echo ""
    echo "  -o, --output-dir"
    echo "      Output directory."
    echo ""

    echo "Optional matched-normal mode:"
    echo "  -n, --normal-bam"
    echo "      Matched normal DNA BAM."
    echo ""
    echo "  -s, --normal-sample-name"
    echo "      SM tag of the normal sample."
    echo ""

    echo "Optional:"
    echo "  -t, --threads"
    echo "      Number of parallel jobs. Default: 8."
    echo ""

    exit 1
}

# =============================================================================
# Variables
# =============================================================================

NUM_PARALLEL_JOBS=8

RNA_BAM_PATH=""
DNA_BAM_PATH=""
DNA_BAM_N=""
NORMAL_SAMPLE_NAME=""

REFERENCE_FASTA=""
PANEL_OF_NORMALS=""
GERMLINE_RESOURCE=""
FUNCOTATOR_DATA_SOURCES=""
HISAT2_INDEX=""
OUTPUT_DIR=""

# =============================================================================
# Parse arguments
# =============================================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        -r|--rna-bam)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            RNA_BAM_PATH="$2"
            shift 2
            ;;

        -n|--normal-bam)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            DNA_BAM_PATH="$2"
            shift 2
            ;;

        -s|--normal-sample-name)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            NORMAL_SAMPLE_NAME="$2"
            shift 2
            ;;

        -g|--genome-fasta)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            REFERENCE_FASTA="$2"
            shift 2
            ;;

        -p|--pon)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            PANEL_OF_NORMALS="$2"
            shift 2
            ;;

        -a|--germline-resource)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            GERMLINE_RESOURCE="$2"
            shift 2
            ;;

        -f|--funcotator-sources)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            FUNCOTATOR_DATA_SOURCES="$2"
            shift 2
            ;;

        -h|--hisat2-index)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            HISAT2_INDEX="$2"
            shift 2
            ;;

        -o|--output-dir)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            OUTPUT_DIR="$2"
            shift 2
            ;;

        -t|--threads)

            [[ $# -ge 2 ]] || {
                echo "ERROR: Missing value for $1"
                usage
            }

            NUM_PARALLEL_JOBS="$2"
            shift 2
            ;;

        -H|--help)

            usage
            ;;

        *)

            echo "ERROR: Unknown parameter: $1"
            usage
            ;;

    esac

done

# =============================================================================
# Validate parameters
# =============================================================================

if [[ -z "${RNA_BAM_PATH}" ||
      -z "${REFERENCE_FASTA}" ||
      -z "${PANEL_OF_NORMALS}" ||
      -z "${GERMLINE_RESOURCE}" ||
      -z "${FUNCOTATOR_DATA_SOURCES}" ||
      -z "${HISAT2_INDEX}" ||
      -z "${OUTPUT_DIR}" ]]; then

    echo "ERROR: One or more required arguments are missing."
    usage

fi

if [[ -n "${DNA_BAM_PATH}" && -z "${NORMAL_SAMPLE_NAME}" ]] ||
   [[ -z "${DNA_BAM_PATH}" && -n "${NORMAL_SAMPLE_NAME}" ]]; then

    echo "ERROR:"
    echo "Matched-normal mode requires BOTH:"
    echo "  --normal-bam"
    echo "  --normal-sample-name"
    exit 1

fi

if [[ -n "${DNA_BAM_PATH}" ]]; then

    DNA_BAM_N="${DNA_BAM_PATH}"

fi

# =============================================================================
# Validate input files/directories
# =============================================================================

echo ""
echo "Validating inputs..."
echo "------------------------------------------------------------"

if [[ ! -f "${RNA_BAM_PATH}" ]]; then
    echo "ERROR: RNA BAM not found:"
    echo "  ${RNA_BAM_PATH}"
    exit 1
fi

if [[ ! -f "${REFERENCE_FASTA}" ]]; then
    echo "ERROR: Reference FASTA not found:"
    echo "  ${REFERENCE_FASTA}"
    exit 1
fi

if [[ ! -f "${REFERENCE_FASTA}.fai" ]]; then
    echo "ERROR: Reference FASTA index not found:"
    echo "  ${REFERENCE_FASTA}.fai"
    exit 1
fi

DICT="${REFERENCE_FASTA%.*}.dict"

if [[ ! -f "${DICT}" ]]; then
    echo "ERROR: Reference sequence dictionary not found:"
    echo "  ${DICT}"
    exit 1
fi

if [[ ! -f "${PANEL_OF_NORMALS}" ]]; then
    echo "ERROR: Panel of Normals not found:"
    echo "  ${PANEL_OF_NORMALS}"
    exit 1
fi

if [[ ! -f "${GERMLINE_RESOURCE}" ]]; then
    echo "ERROR: Germline resource not found:"
    echo "  ${GERMLINE_RESOURCE}"
    exit 1
fi

if [[ ! -d "${FUNCOTATOR_DATA_SOURCES}" ]]; then
    echo "ERROR: Funcotator data sources directory not found:"
    echo "  ${FUNCOTATOR_DATA_SOURCES}"
    exit 1
fi

if [[ -n "${DNA_BAM_PATH}" ]]; then

    if [[ ! -f "${DNA_BAM_PATH}" ]]; then
        echo "ERROR: Normal BAM not found:"
        echo "  ${DNA_BAM_PATH}"
        exit 1
    fi

fi

echo "Input validation: OK"

# =============================================================================
# Start
# =============================================================================

echo ""
echo "============================================================"
echo "Starting RNA-MuTect pipeline"
echo "============================================================"
date

# =============================================================================
# Stage 1 - Setup
# =============================================================================

echo ""
echo "[STAGE 1/5] Setting up directories and variables..."

BASENAME="$(basename "${RNA_BAM_PATH}" .bam)"

mkdir -p "${OUTPUT_DIR}"

REALIGN_DIR="${OUTPUT_DIR}/hisat2"

mkdir -p "${REALIGN_DIR}"

GN="${REFERENCE_FASTA}"

RNA_BAM_SPLIT="${OUTPUT_DIR}/${BASENAME}.split.bam"

MERGED_VCF="${OUTPUT_DIR}/${BASENAME}.merged.vcf.gz"

FUNCOMAF="${OUTPUT_DIR}/${BASENAME}.funcotated.maf"

CONTIG_LIST="$(cut -f1 "${REFERENCE_FASTA}.fai")"

echo "RNA BAM:"
echo "  ${RNA_BAM_PATH}"

echo "Sample:"
echo "  ${BASENAME}"

echo "Reference:"
echo "  ${GN}"

echo "Output:"
echo "  ${OUTPUT_DIR}"

echo "Threads:"
echo "  ${NUM_PARALLEL_JOBS}"

# =============================================================================
# Stage 2 - Initial Mutect2 calling
# =============================================================================

echo ""
echo "[STAGE 2/5] Performing initial variant discovery with Mutect2..."

# -----------------------------------------------------------------------------
# SplitNCigarReads
# -----------------------------------------------------------------------------

echo "--> Running SplitNCigarReads by contig..."

printf "%s\n" "${CONTIG_LIST}" |
xargs -I {} \
      -P "${NUM_PARALLEL_JOBS}" \
      bash -c '

    chr="$1"

    gatk SplitNCigarReads \
        -R "$GN" \
        -I "$RNA_BAM_PATH" \
        -L "$chr" \
        -O "$OUTPUT_DIR/${BASENAME}.${chr}.split.bam"

' _ {}

# -----------------------------------------------------------------------------
# Gather split BAMs
# -----------------------------------------------------------------------------

echo "--> Gathering split BAMs..."

find "${OUTPUT_DIR}" \
    -maxdepth 1 \
    -type f \
    -name "${BASENAME}.*.split.bam" \
    | sort > "${OUTPUT_DIR}/split_bam_list.txt"

if [[ ! -s "${OUTPUT_DIR}/split_bam_list.txt" ]]; then

    echo "ERROR: No split BAM files were generated."

    exit 1

fi

gatk GatherBamFiles \
    -I "${OUTPUT_DIR}/split_bam_list.txt" \
    -O "${RNA_BAM_SPLIT}" \
    -R "${GN}"

samtools index \
    -@ "${NUM_PARALLEL_JOBS}" \
    "${RNA_BAM_SPLIT}"

# -----------------------------------------------------------------------------
# Remove split BAMs
# -----------------------------------------------------------------------------

while read -r b; do

    rm -f "${b}"
    rm -f "${b%.bam}.bai"

done < "${OUTPUT_DIR}/split_bam_list.txt"

rm -f "${OUTPUT_DIR}/split_bam_list.txt"

# -----------------------------------------------------------------------------
# Mutect2
# -----------------------------------------------------------------------------

echo "--> Running Mutect2..."

if [[ -n "${DNA_BAM_N}" ]]; then

    echo " -> Matched-normal mode"

    export GN
    export RNA_BAM_SPLIT
    export PANEL_OF_NORMALS
    export GERMLINE_RESOURCE
    export OUTPUT_DIR
    export BASENAME
    export DNA_BAM_N
    export NORMAL_SAMPLE_NAME

    export MUTECT2_MODE="matched"

else

    echo " -> Tumor-only mode"

    export GN
    export RNA_BAM_SPLIT
    export PANEL_OF_NORMALS
    export GERMLINE_RESOURCE
    export OUTPUT_DIR
    export BASENAME

    export MUTECT2_MODE="tumor_only"

fi

mutect2_contig() {

    local chr="$1"

    local output="${OUTPUT_DIR}/${BASENAME}.${chr}.vcf.gz"

    if [[ "${MUTECT2_MODE}" == "matched" ]]; then

        gatk Mutect2 \
            -R "${GN}" \
            -I "${RNA_BAM_SPLIT}" \
            -I "${DNA_BAM_N}" \
            -normal "${NORMAL_SAMPLE_NAME}" \
            --panel-of-normals "${PANEL_OF_NORMALS}" \
            --germline-resource "${GERMLINE_RESOURCE}" \
            -L "${chr}" \
            -O "${output}"

    else

        gatk Mutect2 \
            -R "${GN}" \
            -I "${RNA_BAM_SPLIT}" \
            --panel-of-normals "${PANEL_OF_NORMALS}" \
            --germline-resource "${GERMLINE_RESOURCE}" \
            -L "${chr}" \
            -O "${output}"

    fi

}

export -f mutect2_contig

printf "%s\n" "${CONTIG_LIST}" |
xargs -I {} \
      -P "${NUM_PARALLEL_JOBS}" \
      bash -c 'mutect2_contig "$1"' _ {}

# -----------------------------------------------------------------------------
# Merge VCF
# -----------------------------------------------------------------------------

echo "--> Merging parallel VCF results..."

find "${OUTPUT_DIR}" \
    -maxdepth 1 \
    -type f \
    -name "${BASENAME}.*.vcf.gz" \
    | sort > "${OUTPUT_DIR}/vcf_list.txt"

if [[ ! -s "${OUTPUT_DIR}/vcf_list.txt" ]]; then

    echo "ERROR: No Mutect2 VCF files were generated."

    exit 1

fi

gatk MergeVcfs \
    -I "${OUTPUT_DIR}/vcf_list.txt" \
    -O "${MERGED_VCF}"

# -----------------------------------------------------------------------------
# Cleanup intermediate VCFs
# -----------------------------------------------------------------------------

while read -r vcf_file; do

    rm -f "${vcf_file}"
    rm -f "${vcf_file}.tbi"
    rm -f "${vcf_file}.stats"

done < "${OUTPUT_DIR}/vcf_list.txt"

rm -f "${OUTPUT_DIR}/vcf_list.txt"

# =============================================================================
# Stage 3 - Funcotator
# =============================================================================

echo ""
echo "[STAGE 3/5] Annotating variants with Funcotator..."

funcotator_contig() {

    local chr="$1"

    echo "    -> Annotating contig: ${chr}"

    gatk Funcotator \
        --variant "${MERGED_VCF}" \
        --reference "${GN}" \
        --ref-version hg38 \
        -L "${chr}" \
        --data-sources-path "${FUNCOTATOR_DATA_SOURCES}" \
        --output "${OUTPUT_DIR}/${BASENAME}.${chr}.maf" \
        --output-file-format MAF

}

export -f funcotator_contig

export MERGED_VCF
export GN
export FUNCOTATOR_DATA_SOURCES
export OUTPUT_DIR
export BASENAME

printf "%s\n" "${CONTIG_LIST}" |
xargs -I {} \
      -P "${NUM_PARALLEL_JOBS}" \
      bash -c 'funcotator_contig "$1"' _ {}

# -----------------------------------------------------------------------------
# Merge MAFs
# -----------------------------------------------------------------------------

echo "--> Merging MAF results..."

mapfile -t MAF_FILES < <(
    find "${OUTPUT_DIR}" \
        -maxdepth 1 \
        -type f \
        -name "${BASENAME}.*.maf" \
        -size +0c \
        | sort
)

if [[ "${#MAF_FILES[@]}" -eq 0 ]]; then

    echo "FATAL: No MAF files were generated by Funcotator."

    exit 1

fi

FIRST_MAF="${MAF_FILES[0]}"

grep "^Hugo_Symbol" "${FIRST_MAF}" > "${FUNCOMAF}"

for maf in "${MAF_FILES[@]}"; do

    grep -hv "^Hugo_Symbol" "${maf}" >> "${FUNCOMAF}"

done

for maf in "${MAF_FILES[@]}"; do

    rm -f "${maf}"

done

# =============================================================================
# Stage 4 - Targeted re-alignment
# =============================================================================

echo ""
echo "[STAGE 4/5] Performing targeted re-alignment with HISAT2..."

# -----------------------------------------------------------------------------
# Create BED
# -----------------------------------------------------------------------------

echo "--> Creating BED file from MAF..."

awk '
BEGIN {
    OFS="\t"
}

NR > 1 &&
!/^#/ &&
$6 ~ /^[0-9]+$/ &&
$7 ~ /^[0-9]+$/ {

    chrom = $5

    if (chrom == "MT") {

        chrom = "chrM"

    } else if (chrom !~ /^KN/ && chrom !~ /^JTFH/) {

        if (chrom !~ /^chr/) {

            chrom = "chr" chrom

        }

    }

    start = $6 - 1
    end = $7

    print chrom, start, end
}
' "${FUNCOMAF}" \
> "${REALIGN_DIR}/variants.bed"

if [[ ! -s "${REALIGN_DIR}/variants.bed" ]]; then

    echo "ERROR: No variants were found for re-alignment."

    exit 1

fi

# -----------------------------------------------------------------------------
# BED -> IntervalList
# -----------------------------------------------------------------------------

gatk BedToIntervalList \
    -I "${REALIGN_DIR}/variants.bed" \
    -O "${REALIGN_DIR}/variants.interval_list" \
    -SD "${GN}"

# -----------------------------------------------------------------------------
# RNA read names
# -----------------------------------------------------------------------------

echo "--> Extracting RNA read names..."

samtools view \
    -@ "${NUM_PARALLEL_JOBS}" \
    -L "${REALIGN_DIR}/variants.bed" \
    "${RNA_BAM_PATH}" |
cut -f1 |
sort -u \
> "${REALIGN_DIR}/${BASENAME}_read_names.txt"

# -----------------------------------------------------------------------------
# Filter RNA BAM
# -----------------------------------------------------------------------------

gatk FilterSamReads \
    -I "${RNA_BAM_PATH}" \
    -O "${REALIGN_DIR}/${BASENAME}.filtered.bam" \
    --READ_LIST_FILE "${REALIGN_DIR}/${BASENAME}_read_names.txt" \
    --FILTER includeReadList

# -----------------------------------------------------------------------------
# BAM -> FASTQ
# -----------------------------------------------------------------------------

gatk SamToFastq \
    -I "${REALIGN_DIR}/${BASENAME}.filtered.bam" \
    -F "${REALIGN_DIR}/${BASENAME}_1.fastq.gz" \
    -F2 "${REALIGN_DIR}/${BASENAME}_2.fastq.gz"

# -----------------------------------------------------------------------------
# HISAT2 RNA
# -----------------------------------------------------------------------------

echo "--> Re-aligning RNA reads..."

hisat2 \
    -p "${NUM_PARALLEL_JOBS}" \
    -x "${HISAT2_INDEX}" \
    -1 "${REALIGN_DIR}/${BASENAME}_1.fastq.gz" \
    -2 "${REALIGN_DIR}/${BASENAME}_2.fastq.gz" \
    --summary-file "${REALIGN_DIR}/${BASENAME}.hisat2.summary.txt" \
    --rg-id "${BASENAME}" \
    --rg "SM:${BASENAME}" |
samtools sort \
    -@ "${NUM_PARALLEL_JOBS}" \
    -o "${REALIGN_DIR}/${BASENAME}.realigned.bam"

samtools index \
    -@ "${NUM_PARALLEL_JOBS}" \
    "${REALIGN_DIR}/${BASENAME}.realigned.bam"

# -----------------------------------------------------------------------------
# Optional normal DNA re-alignment
# -----------------------------------------------------------------------------

if [[ -n "${DNA_BAM_N}" ]]; then

    echo "--> Re-aligning DNA reads..."

    samtools view \
        -@ "${NUM_PARALLEL_JOBS}" \
        -L "${REALIGN_DIR}/variants.bed" \
        "${DNA_BAM_N}" |
    cut -f1 |
    sort -u \
    > "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_read_names.txt"

    gatk FilterSamReads \
        -I "${DNA_BAM_N}" \
        -O "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.filtered.bam" \
        --READ_LIST_FILE "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_read_names.txt" \
        --FILTER includeReadList

    gatk SamToFastq \
        -I "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.filtered.bam" \
        -F "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_1.fastq.gz" \
        -F2 "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_2.fastq.gz"

    hisat2 \
        -p "${NUM_PARALLEL_JOBS}" \
        -x "${HISAT2_INDEX}" \
        -1 "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_1.fastq.gz" \
        -2 "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_2.fastq.gz" \
        --summary-file "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.hisat2.summary.txt" \
        --rg-id "${NORMAL_SAMPLE_NAME}" \
        --rg "SM:${NORMAL_SAMPLE_NAME}" |
    samtools sort \
        -@ "${NUM_PARALLEL_JOBS}" \
        -o "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam"

    samtools index \
        -@ "${NUM_PARALLEL_JOBS}" \
        "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam"

fi

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

rm -f "${REALIGN_DIR}"/*.filtered.bam
rm -f "${REALIGN_DIR}"/*_read_names.txt

# =============================================================================
# Stage 5 - Final Mutect2
# =============================================================================

echo ""
echo "[STAGE 5/5] Final variant re-calling..."

FINAL_VCF_OUT="${REALIGN_DIR}/${BASENAME}.realigned.vcf.gz"

if [[ -n "${DNA_BAM_N}" ]]; then

    echo "--> Final Mutect2 in matched-normal mode..."

    gatk Mutect2 \
        -R "${GN}" \
        -I "${REALIGN_DIR}/${BASENAME}.realigned.bam" \
        -I "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam" \
        -normal "${NORMAL_SAMPLE_NAME}" \
        -L "${REALIGN_DIR}/variants.interval_list" \
        --germline-resource "${GERMLINE_RESOURCE}" \
        --panel-of-normals "${PANEL_OF_NORMALS}" \
        -O "${FINAL_VCF_OUT}"

else

    echo "--> Final Mutect2 in tumor-only mode..."

    gatk Mutect2 \
        -R "${GN}" \
        -I "${REALIGN_DIR}/${BASENAME}.realigned.bam" \
        -L "${REALIGN_DIR}/variants.interval_list" \
        --germline-resource "${GERMLINE_RESOURCE}" \
        --panel-of-normals "${PANEL_OF_NORMALS}" \
        -O "${FINAL_VCF_OUT}"

fi

# =============================================================================
# Complete
# =============================================================================

echo ""
echo "============================================================"
echo "RNA-MuTect pipeline completed successfully."
echo "============================================================"

echo ""
echo "Output directory:"
echo "  ${OUTPUT_DIR}"

echo ""
echo "Final VCF:"
echo "  ${FINAL_VCF_OUT}"

date
