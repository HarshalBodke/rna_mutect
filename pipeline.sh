#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# RNA-MuTect Pipeline
#
# Five-stage workflow
#
#   Stage 1  Setup / validation
#   Stage 2  SplitNCigarReads + initial Mutect2
#   Stage 3  Funcotator annotation
#   Stage 4  Targeted HISAT2 re-alignment
#   Stage 5  Final Mutect2
#
# The entrypoint normalizes:
#
#   - HISAT2 archive -> HISAT2 index prefix
#   - Funcotator archive -> Funcotator data-source directory
#
# This script therefore expects:
#
#   -r RNA BAM
#   -g reference FASTA
#   -p Panel of Normals VCF
#   -a germline resource VCF
#   -f Funcotator data-source directory
#   -h HISAT2 index prefix
#   -o output directory
#
# Optional:
#
#   -n normal DNA BAM
#   -s normal sample name
#   -t number of contig jobs in parallel
# =============================================================================


# =============================================================================
# Usage
# =============================================================================

usage() {

    cat <<'EOF'

Usage:

  pipeline.sh \
      -r <RNA_BAM> \
      -g <REFERENCE_FASTA> \
      -p <PANEL_OF_NORMALS_VCF> \
      -a <GERMLINE_RESOURCE_VCF> \
      -f <FUNCOTATOR_DATA_SOURCE_DIRECTORY> \
      -h <HISAT2_INDEX_PREFIX> \
      -o <OUTPUT_DIRECTORY> \
      [-n <NORMAL_DNA_BAM> -s <NORMAL_SAMPLE_NAME>] \
      [-t <PARALLEL_JOBS>]

Required:

  -r, --rna-bam
      Input RNA-aligned BAM.

  -g, --genome-fasta
      Reference genome FASTA.

      Required companion files:
        <reference>.fai
        <reference-without-.fa/.fasta>.dict

  -p, --pon
      Panel of Normals VCF.

  -a, --germline-resource
      Germline resource VCF.

  -f, --funcotator-sources
      Funcotator data-source root directory.

  -h, --hisat2-index
      HISAT2 index prefix.

  -o, --output-dir
      Output directory.

Optional matched-normal mode:

  -n, --normal-bam
      Matched normal DNA BAM.

  -s, --normal-sample-name
      SM tag of the normal sample.

Optional:

  -t, --threads
      Number of contig-level jobs to run in parallel.
      Default: 8.

Notes:

  The value of -t controls parallel contig jobs. It is not the number
  of threads allocated internally to every GATK process.

EOF

    exit 1
}


# =============================================================================
# Utility functions
# =============================================================================

die() {

    echo ""
    echo "ERROR: $*" >&2

    exit 1
}


info() {

    echo ""
    echo "$*"

}


require_file() {

    local file="$1"
    local description="$2"

    [[ -f "${file}" ]] ||
        die "${description} not found: ${file}"

}


require_directory() {

    local dir="$1"
    local description="$2"

    [[ -d "${dir}" ]] ||
        die "${description} not found: ${dir}"

}


# =============================================================================
# Variables
# =============================================================================

NUM_PARALLEL_JOBS=8

RNA_BAM_PATH=""
DNA_BAM_PATH=""
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

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            RNA_BAM_PATH="$2"
            shift 2
            ;;


        -n|--normal-bam)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            DNA_BAM_PATH="$2"
            shift 2
            ;;


        -s|--normal-sample-name)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            NORMAL_SAMPLE_NAME="$2"
            shift 2
            ;;


        -g|--genome-fasta)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            REFERENCE_FASTA="$2"
            shift 2
            ;;


        -p|--pon)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            PANEL_OF_NORMALS="$2"
            shift 2
            ;;


        -a|--germline-resource)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            GERMLINE_RESOURCE="$2"
            shift 2
            ;;


        -f|--funcotator-sources)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            FUNCOTATOR_DATA_SOURCES="$2"
            shift 2
            ;;


        -h|--hisat2-index)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            HISAT2_INDEX="$2"
            shift 2
            ;;


        -o|--output-dir)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            OUTPUT_DIR="$2"
            shift 2
            ;;


        -t|--threads)

            [[ $# -ge 2 ]] ||
                die "Missing value after $1"

            NUM_PARALLEL_JOBS="$2"
            shift 2
            ;;


        -H|--help)

            usage
            ;;


        *)

            die "Unknown parameter: $1"

            ;;

    esac

done


# =============================================================================
# Required parameter validation
# =============================================================================

if [[ -z "${RNA_BAM_PATH}" ||
      -z "${REFERENCE_FASTA}" ||
      -z "${PANEL_OF_NORMALS}" ||
      -z "${GERMLINE_RESOURCE}" ||
      -z "${FUNCOTATOR_DATA_SOURCES}" ||
      -z "${HISAT2_INDEX}" ||
      -z "${OUTPUT_DIR}" ]]; then

    usage

fi


# =============================================================================
# Validate parallel jobs
# =============================================================================

if ! [[ "${NUM_PARALLEL_JOBS}" =~ ^[1-9][0-9]*$ ]]; then

    die "Parallel jobs must be a positive integer: ${NUM_PARALLEL_JOBS}"

fi


# =============================================================================
# Validate matched-normal parameters
# =============================================================================

if [[ -n "${DNA_BAM_PATH}" && -z "${NORMAL_SAMPLE_NAME}" ]]; then

    die "Matched-normal mode requires --normal-sample-name."

fi


if [[ -z "${DNA_BAM_PATH}" && -n "${NORMAL_SAMPLE_NAME}" ]]; then

    die "A normal sample name was supplied without --normal-bam."

fi


# =============================================================================
# Validate input files
# =============================================================================

info "Validating inputs..."
echo "------------------------------------------------------------"


require_file \
    "${RNA_BAM_PATH}" \
    "RNA BAM"


require_file \
    "${REFERENCE_FASTA}" \
    "Reference FASTA"


require_file \
    "${REFERENCE_FASTA}.fai" \
    "Reference FASTA index"


# Determine dictionary path.
#
# Examples:
#
#   genome.fa       -> genome.dict
#   genome.fasta    -> genome.dict
#   genome.fna      -> genome.dict
#
# For unusual extensions, remove only the final extension.

REFERENCE_BASENAME="${REFERENCE_FASTA%.*}"
REFERENCE_DICT="${REFERENCE_BASENAME}.dict"


require_file \
    "${REFERENCE_DICT}" \
    "Reference sequence dictionary"


require_file \
    "${PANEL_OF_NORMALS}" \
    "Panel of Normals VCF"


require_file \
    "${GERMLINE_RESOURCE}" \
    "Germline resource VCF"


require_directory \
    "${FUNCOTATOR_DATA_SOURCES}" \
    "Funcotator data-source directory"


# =============================================================================
# Validate VCF indexes
# =============================================================================

if [[ ! -f "${PANEL_OF_NORMALS}.tbi" &&
      ! -f "${PANEL_OF_NORMALS}.csi" ]]; then

    die "Panel of Normals index not found. Expected .tbi or .csi: ${PANEL_OF_NORMALS}"

fi


if [[ ! -f "${GERMLINE_RESOURCE}.tbi" &&
      ! -f "${GERMLINE_RESOURCE}.csi" ]]; then

    die "Germline resource index not found. Expected .tbi or .csi: ${GERMLINE_RESOURCE}"

fi


# =============================================================================
# Validate RNA BAM index
# =============================================================================

RNA_BAM_INDEX=""

if [[ -f "${RNA_BAM_PATH}.bai" ]]; then

    RNA_BAM_INDEX="${RNA_BAM_PATH}.bai"

elif [[ "${RNA_BAM_PATH}" == *.bam &&
        -f "${RNA_BAM_PATH%.bam}.bai" ]]; then

    RNA_BAM_INDEX="${RNA_BAM_PATH%.bam}.bai"

else

    die "RNA BAM index not found for: ${RNA_BAM_PATH}"

fi


# =============================================================================
# Validate normal BAM/index
# =============================================================================

NORMAL_BAM_INDEX=""

if [[ -n "${DNA_BAM_PATH}" ]]; then

    require_file \
        "${DNA_BAM_PATH}" \
        "Normal DNA BAM"


    if [[ -f "${DNA_BAM_PATH}.bai" ]]; then

        NORMAL_BAM_INDEX="${DNA_BAM_PATH}.bai"

    elif [[ "${DNA_BAM_PATH}" == *.bam &&
            -f "${DNA_BAM_PATH%.bam}.bai" ]]; then

        NORMAL_BAM_INDEX="${DNA_BAM_PATH%.bam}.bai"

    else

        die "Normal DNA BAM index not found for: ${DNA_BAM_PATH}"

    fi

fi


# =============================================================================
# Validate HISAT2 index
# =============================================================================

info "Validating HISAT2 index..."
echo "------------------------------------------------------------"


HISAT2_INDEX_EXTENSION=""

if [[ -f "${HISAT2_INDEX}.1.ht2" ]]; then

    HISAT2_INDEX_EXTENSION="ht2"

elif [[ -f "${HISAT2_INDEX}.1.ht2l" ]]; then

    HISAT2_INDEX_EXTENSION="ht2l"

else

    die "HISAT2 index prefix is invalid: ${HISAT2_INDEX}"

fi


for i in {1..8}; do

    require_file \
        "${HISAT2_INDEX}.${i}.${HISAT2_INDEX_EXTENSION}" \
        "HISAT2 index component"

done


echo "HISAT2 index validation: OK"


# =============================================================================
# Determine reference contigs
#
# The FASTA .fai is authoritative.
#
# This deliberately preserves the exact naming used by the reference:
#
#   chr1
#   chr2
#   ...
#
# OR:
#
#   1
#   2
#   ...
#
# OR any other valid reference contig naming.
# =============================================================================

mapfile -t CONTIGS < <(
    cut -f1 "${REFERENCE_FASTA}.fai"
)


if [[ "${#CONTIGS[@]}" -eq 0 ]]; then

    die "No contigs were found in ${REFERENCE_FASTA}.fai"

fi


echo ""
echo "Reference contigs:"
echo "  ${#CONTIGS[@]}"


# =============================================================================
# Determine sample name
# =============================================================================

BASENAME="$(basename "${RNA_BAM_PATH}")"

case "${BASENAME}" in

    *.bam)
        BASENAME="${BASENAME%.bam}"
        ;;

esac


[[ -n "${BASENAME}" ]] ||
    die "Could not determine sample name from RNA BAM."


# =============================================================================
# Create output directories
# =============================================================================

mkdir -p "${OUTPUT_DIR}"

REALIGN_DIR="${OUTPUT_DIR}/hisat2"

mkdir -p "${REALIGN_DIR}"


# =============================================================================
# Define output files
# =============================================================================

RNA_BAM_SPLIT="${OUTPUT_DIR}/${BASENAME}.split.bam"

MERGED_VCF="${OUTPUT_DIR}/${BASENAME}.merged.vcf.gz"

FUNCOMAF="${OUTPUT_DIR}/${BASENAME}.funcotated.maf"

FINAL_VCF_OUT="${REALIGN_DIR}/${BASENAME}.realigned.vcf.gz"


CONTIG_FILE="${OUTPUT_DIR}/reference_contigs.txt"


printf '%s\n' "${CONTIGS[@]}" > "${CONTIG_FILE}"


# =============================================================================
# Pipeline summary
# =============================================================================

echo ""
echo "============================================================"
echo "RNA-MuTect pipeline configuration"
echo "============================================================"

echo ""
echo "RNA BAM:"
echo "  ${RNA_BAM_PATH}"

echo ""
echo "RNA BAM index:"
echo "  ${RNA_BAM_INDEX}"

echo ""
echo "Sample:"
echo "  ${BASENAME}"

echo ""
echo "Reference:"
echo "  ${REFERENCE_FASTA}"

echo ""
echo "Reference dictionary:"
echo "  ${REFERENCE_DICT}"

echo ""
echo "Panel of Normals:"
echo "  ${PANEL_OF_NORMALS}"

echo ""
echo "Germline resource:"
echo "  ${GERMLINE_RESOURCE}"

echo ""
echo "Funcotator data sources:"
echo "  ${FUNCOTATOR_DATA_SOURCES}"

echo ""
echo "HISAT2 index:"
echo "  ${HISAT2_INDEX}"

echo ""
echo "Output:"
echo "  ${OUTPUT_DIR}"

echo ""
echo "Parallel contig jobs:"
echo "  ${NUM_PARALLEL_JOBS}"

if [[ -n "${DNA_BAM_PATH}" ]]; then

    echo ""
    echo "Mode:"
    echo "  Matched normal"

    echo ""
    echo "Normal BAM:"
    echo "  ${DNA_BAM_PATH}"

    echo ""
    echo "Normal sample:"
    echo "  ${NORMAL_SAMPLE_NAME}"

else

    echo ""
    echo "Mode:"
    echo "  Tumor-only"

fi


echo ""
echo "Input validation: OK"


# =============================================================================
# Determine whether RNA data are paired-end
#
# FLAG 0x1 indicates a paired read.
# =============================================================================

RNA_PAIRED_COUNT="$(
    samtools view \
        -c \
        -f 1 \
        "${RNA_BAM_PATH}"
)"


if [[ "${RNA_PAIRED_COUNT}" -gt 0 ]]; then

    RNA_IS_PAIRED="true"

else

    RNA_IS_PAIRED="false"

fi


echo ""
echo "RNA sequencing layout:"
if [[ "${RNA_IS_PAIRED}" == "true" ]]; then
    echo "  Paired-end"
else
    echo "  Single-end"
fi


# =============================================================================
# Determine whether normal DNA is paired-end
# =============================================================================

NORMAL_IS_PAIRED="false"

if [[ -n "${DNA_BAM_PATH}" ]]; then

    NORMAL_PAIRED_COUNT="$(
        samtools view \
            -c \
            -f 1 \
            "${DNA_BAM_PATH}"
    )"


    if [[ "${NORMAL_PAIRED_COUNT}" -gt 0 ]]; then
        NORMAL_IS_PAIRED="true"
    fi

fi


# =============================================================================
# Stage 1 - Setup
# =============================================================================

echo ""
echo "============================================================"
echo "[STAGE 1/5] Setting up directories and variables"
echo "============================================================"

date


# =============================================================================
# Stage 2 - Initial variant discovery
# =============================================================================

echo ""
echo "============================================================"
echo "[STAGE 2/5] Initial variant discovery with Mutect2"
echo "============================================================"


# -----------------------------------------------------------------------------
# SplitNCigarReads
#
# We scatter by the exact reference contig order.
# -----------------------------------------------------------------------------

echo ""
echo "--> Running SplitNCigarReads by contig..."


export GN="${REFERENCE_FASTA}"
export RNA_BAM_PATH
export OUTPUT_DIR
export BASENAME


split_n_cigar_contig() {

    local chr="$1"

    echo "    -> SplitNCigarReads: ${chr}"


    gatk SplitNCigarReads \
        -R "${GN}" \
        -I "${RNA_BAM_PATH}" \
        -L "${chr}" \
        -O "${OUTPUT_DIR}/${BASENAME}.${chr}.split.bam"

}


export -f split_n_cigar_contig


cat "${CONTIG_FILE}" |
xargs -r -I {} \
    -P "${NUM_PARALLEL_JOBS}" \
    bash -c 'split_n_cigar_contig "$1"' _ {}


# -----------------------------------------------------------------------------
# Verify split BAMs and build reference-ordered list
# -----------------------------------------------------------------------------

mapfile -t SPLIT_BAMS < <(
    while IFS= read -r chr; do

        bam="${OUTPUT_DIR}/${BASENAME}.${chr}.split.bam"

        if [[ -f "${bam}" ]]; then
            printf '%s\n' "${bam}"
        fi

    done < "${CONTIG_FILE}"
)


if [[ "${#SPLIT_BAMS[@]}" -eq 0 ]]; then

    die "No SplitNCigarReads BAM files were generated."

fi


if [[ "${#SPLIT_BAMS[@]}" -ne "${#CONTIGS[@]}" ]]; then

    die "Expected ${#CONTIGS[@]} split BAM files but found ${#SPLIT_BAMS[@]}."

fi


echo ""
echo "--> Gathering split BAMs..."


SPLIT_BAM_LIST="${OUTPUT_DIR}/split_bam_list.list"

printf '%s\n' "${SPLIT_BAMS[@]}" > "${SPLIT_BAM_LIST}"


gatk GatherBamFiles \
    -I "${SPLIT_BAM_LIST}" \
    -O "${RNA_BAM_SPLIT}" \
    -R "${REFERENCE_FASTA}"


samtools index \
    -@ "${NUM_PARALLEL_JOBS}" \
    "${RNA_BAM_SPLIT}"


[[ -f "${RNA_BAM_SPLIT}" ]] ||
    die "Gathered split BAM was not created."


[[ -f "${RNA_BAM_SPLIT}.bai" ]] ||
    die "Gathered split BAM index was not created."


# Cleanup split BAMs.

while IFS= read -r bam; do

    rm -f "${bam}"
    rm -f "${bam}.bai"
    rm -f "${bam%.bam}.bai"

done < "${SPLIT_BAM_LIST}"


rm -f "${SPLIT_BAM_LIST}"


# -----------------------------------------------------------------------------
# Initial Mutect2
# -----------------------------------------------------------------------------

echo ""
echo "--> Running initial Mutect2..."


if [[ -n "${DNA_BAM_PATH}" ]]; then

    MUTECT2_MODE="matched"

    echo "    Mode: matched normal"

else

    MUTECT2_MODE="tumor_only"

    echo "    Mode: tumor-only"

fi


export GN="${REFERENCE_FASTA}"
export RNA_BAM_SPLIT
export PANEL_OF_NORMALS
export GERMLINE_RESOURCE
export OUTPUT_DIR
export BASENAME
export DNA_BAM_PATH
export NORMAL_SAMPLE_NAME
export MUTECT2_MODE


mutect2_contig() {

    local chr="$1"

    local output="${OUTPUT_DIR}/${BASENAME}.${chr}.vcf.gz"


    echo "    -> Mutect2: ${chr}"


    if [[ "${MUTECT2_MODE}" == "matched" ]]; then

        gatk Mutect2 \
            -R "${GN}" \
            -I "${RNA_BAM_SPLIT}" \
            -I "${DNA_BAM_PATH}" \
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


    [[ -f "${output}" ]] ||
        return 1

}


export -f mutect2_contig


cat "${CONTIG_FILE}" |
xargs -r -I {} \
    -P "${NUM_PARALLEL_JOBS}" \
    bash -c 'mutect2_contig "$1"' _ {}


# -----------------------------------------------------------------------------
# Verify and merge Mutect2 VCFs in reference order
# -----------------------------------------------------------------------------

mapfile -t MUTECT_VCFS < <(
    while IFS= read -r chr; do

        vcf="${OUTPUT_DIR}/${BASENAME}.${chr}.vcf.gz"

        if [[ -f "${vcf}" ]]; then
            printf '%s\n' "${vcf}"
        fi

    done < "${CONTIG_FILE}"
)


if [[ "${#MUTECT_VCFS[@]}" -eq 0 ]]; then

    die "No Mutect2 VCF files were generated."

fi


if [[ "${#MUTECT_VCFS[@]}" -ne "${#CONTIGS[@]}" ]]; then

    die "Expected ${#CONTIGS[@]} Mutect2 VCF files but found ${#MUTECT_VCFS[@]}."

fi


echo ""
echo "--> Merging Mutect2 VCF results..."


VCF_LIST="${OUTPUT_DIR}/vcf_list.list"

printf '%s\n' "${MUTECT_VCFS[@]}" > "${VCF_LIST}"


gatk MergeVcfs \
    -I "${VCF_LIST}" \
    -D "${REFERENCE_DICT}" \
    -O "${MERGED_VCF}"


[[ -f "${MERGED_VCF}" ]] ||
    die "Merged VCF was not created."


[[ -f "${MERGED_VCF}.tbi" ||
   -f "${MERGED_VCF}.csi" ]] ||
    die "Merged VCF index was not created."


# Cleanup scattered VCFs.

while IFS= read -r vcf_file; do

    rm -f "${vcf_file}"
    rm -f "${vcf_file}.tbi"
    rm -f "${vcf_file}.csi"
    rm -f "${vcf_file}.stats"

done < "${VCF_LIST}"


rm -f "${VCF_LIST}"


# =============================================================================
# Stage 3 - Funcotator
# =============================================================================

echo ""
echo "============================================================"
echo "[STAGE 3/5] Annotating variants with Funcotator"
echo "============================================================"


funcotator_contig() {

    local chr="$1"

    local output="${OUTPUT_DIR}/${BASENAME}.${chr}.maf"


    echo "    -> Funcotator: ${chr}"


    gatk Funcotator \
        --variant "${MERGED_VCF}" \
        --reference "${GN}" \
        --ref-version hg38 \
        -L "${chr}" \
        --data-sources-path "${FUNCOTATOR_DATA_SOURCES}" \
        --output "${output}" \
        --output-file-format MAF


    [[ -s "${output}" ]] ||
        return 1

}


export -f funcotator_contig

export MERGED_VCF
export GN
export FUNCOTATOR_DATA_SOURCES
export OUTPUT_DIR
export BASENAME


cat "${CONTIG_FILE}" |
xargs -r -I {} \
    -P "${NUM_PARALLEL_JOBS}" \
    bash -c 'funcotator_contig "$1"' _ {}


# -----------------------------------------------------------------------------
# Merge MAF files
# -----------------------------------------------------------------------------

echo ""
echo "--> Merging Funcotator MAF files..."


mapfile -t MAF_FILES < <(
    while IFS= read -r chr; do

        maf="${OUTPUT_DIR}/${BASENAME}.${chr}.maf"

        if [[ -s "${maf}" ]]; then
            printf '%s\n' "${maf}"
        fi

    done < "${CONTIG_FILE}"
)


if [[ "${#MAF_FILES[@]}" -eq 0 ]]; then

    die "No MAF files were generated by Funcotator."

fi


FIRST_MAF="${MAF_FILES[0]}"


grep -m 1 '^Hugo_Symbol' "${FIRST_MAF}" > "${FUNCOMAF}" ||
    die "Could not find Hugo_Symbol header in Funcotator output."


for maf in "${MAF_FILES[@]}"; do

    grep -v '^Hugo_Symbol' "${maf}" >> "${FUNCOMAF}"

done


[[ -s "${FUNCOMAF}" ]] ||
    die "Final Funcotator MAF is empty."


# Remove per-contig MAFs.

for maf in "${MAF_FILES[@]}"; do

    rm -f "${maf}"

done


# =============================================================================
# Stage 4 - Targeted re-alignment
# =============================================================================

echo ""
echo "============================================================"
echo "[STAGE 4/5] Targeted RNA re-alignment with HISAT2"
echo "============================================================"


# -----------------------------------------------------------------------------
# Create BED
#
# IMPORTANT:
# The reference FASTA naming is authoritative.
#
# We do not add/remove 'chr' blindly.
# -----------------------------------------------------------------------------

echo ""
echo "--> Creating BED file from MAF..."


REFERENCE_CONTIG_SET="${REALIGN_DIR}/reference_contigs.set"

awk '{print $1}' "${REFERENCE_FASTA}.fai" |
    sort -u \
    > "${REFERENCE_CONTIG_SET}"


awk -v ref="${REFERENCE_CONTIG_SET}" '

BEGIN {
    OFS="\t"

    while ((getline c < ref) > 0) {
        valid[c] = 1
    }

    close(ref)
}

NR > 1 &&
!/^#/ &&
$6 ~ /^[0-9]+$/ &&
$7 ~ /^[0-9]+$/ {

    chrom = $5

    # Direct match to reference.
    if (chrom in valid) {

        final_chrom = chrom

    }

    # Common MT/chrM aliases.
    else if (chrom == "MT" && ("chrM" in valid)) {

        final_chrom = "chrM"

    }

    else if (chrom == "chrM" && ("MT" in valid)) {

        final_chrom = "MT"

    }

    # chrN -> N
    else if (chrom ~ /^chr/ &&
             substr(chrom, 4) in valid) {

        final_chrom = substr(chrom, 4)

    }

    # N -> chrN
    else if (("chr" chrom) in valid) {

        final_chrom = "chr" chrom

    }

    else {

        next

    }


    start = $6 - 1
    end = $7


    if (start < 0) {
        start = 0
    }


    print final_chrom, start, end
}

' "${FUNCOMAF}" \
> "${REALIGN_DIR}/variants.bed"


if [[ ! -s "${REALIGN_DIR}/variants.bed" ]]; then

    die "No reference-compatible variants were found for targeted re-alignment."

fi


# Remove duplicate intervals.

sort -u \
    "${REALIGN_DIR}/variants.bed" \
    -o "${REALIGN_DIR}/variants.bed"


# -----------------------------------------------------------------------------
# BED -> IntervalList
# -----------------------------------------------------------------------------

echo ""
echo "--> Creating interval list..."


gatk BedToIntervalList \
    -I "${REALIGN_DIR}/variants.bed" \
    -O "${REALIGN_DIR}/variants.interval_list" \
    -SD "${REFERENCE_DICT}"


[[ -s "${REALIGN_DIR}/variants.interval_list" ]] ||
    die "No intervals were created."


# -----------------------------------------------------------------------------
# Extract RNA read names
# -----------------------------------------------------------------------------

echo ""
echo "--> Extracting RNA read names..."


samtools view \
    -@ "${NUM_PARALLEL_JOBS}" \
    -L "${REALIGN_DIR}/variants.bed" \
    "${RNA_BAM_PATH}" |
    cut -f1 |
    sort -u \
    > "${REALIGN_DIR}/${BASENAME}_read_names.txt"


if [[ ! -s "${REALIGN_DIR}/${BASENAME}_read_names.txt" ]]; then

    die "No RNA reads overlap the detected variant intervals."

fi


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
#
# Support both paired-end and single-end RNA BAMs.
# -----------------------------------------------------------------------------

if [[ "${RNA_IS_PAIRED}" == "true" ]]; then

    echo ""
    echo "--> Converting paired-end RNA BAM to FASTQ..."


    gatk SamToFastq \
        -I "${REALIGN_DIR}/${BASENAME}.filtered.bam" \
        -F "${REALIGN_DIR}/${BASENAME}_1.fastq.gz" \
        -F2 "${REALIGN_DIR}/${BASENAME}_2.fastq.gz"

else

    echo ""
    echo "--> Converting single-end RNA BAM to FASTQ..."


    gatk SamToFastq \
        -I "${REALIGN_DIR}/${BASENAME}.filtered.bam" \
        -F "${REALIGN_DIR}/${BASENAME}.fastq.gz"

fi


# -----------------------------------------------------------------------------
# HISAT2 RNA re-alignment
# -----------------------------------------------------------------------------

echo ""
echo "--> Re-aligning RNA reads with HISAT2..."


if [[ "${RNA_IS_PAIRED}" == "true" ]]; then

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

else

    hisat2 \
        -p "${NUM_PARALLEL_JOBS}" \
        -x "${HISAT2_INDEX}" \
        -U "${REALIGN_DIR}/${BASENAME}.fastq.gz" \
        --summary-file "${REALIGN_DIR}/${BASENAME}.hisat2.summary.txt" \
        --rg-id "${BASENAME}" \
        --rg "SM:${BASENAME}" |
    samtools sort \
        -@ "${NUM_PARALLEL_JOBS}" \
        -o "${REALIGN_DIR}/${BASENAME}.realigned.bam"

fi


samtools index \
    -@ "${NUM_PARALLEL_JOBS}" \
    "${REALIGN_DIR}/${BASENAME}.realigned.bam"


[[ -f "${REALIGN_DIR}/${BASENAME}.realigned.bam" ]] ||
    die "RNA realigned BAM was not created."


[[ -f "${REALIGN_DIR}/${BASENAME}.realigned.bam.bai" ]] ||
    die "RNA realigned BAM index was not created."


# -----------------------------------------------------------------------------
# Optional normal DNA re-alignment
# -----------------------------------------------------------------------------

if [[ -n "${DNA_BAM_PATH}" ]]; then

    echo ""
    echo "--> Re-aligning matched-normal DNA reads..."


    samtools view \
        -@ "${NUM_PARALLEL_JOBS}" \
        -L "${REALIGN_DIR}/variants.bed" \
        "${DNA_BAM_PATH}" |
        cut -f1 |
        sort -u \
        > "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_read_names.txt"


    if [[ ! -s "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_read_names.txt" ]]; then

        die "No normal DNA reads overlap the detected variant intervals."

    fi


    gatk FilterSamReads \
        -I "${DNA_BAM_PATH}" \
        -O "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.filtered.bam" \
        --READ_LIST_FILE "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}_read_names.txt" \
        --FILTER includeReadList


    if [[ "${NORMAL_IS_PAIRED}" == "true" ]]; then

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

    else

        gatk SamToFastq \
            -I "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.filtered.bam" \
            -F "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.fastq.gz"


        hisat2 \
            -p "${NUM_PARALLEL_JOBS}" \
            -x "${HISAT2_INDEX}" \
            -U "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.fastq.gz" \
            --summary-file "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.hisat2.summary.txt" \
            --rg-id "${NORMAL_SAMPLE_NAME}" \
            --rg "SM:${NORMAL_SAMPLE_NAME}" |
        samtools sort \
            -@ "${NUM_PARALLEL_JOBS}" \
            -o "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam"

    fi


    samtools index \
        -@ "${NUM_PARALLEL_JOBS}" \
        "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam"


    [[ -f "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam" ]] ||
        die "Normal realigned BAM was not created."


    [[ -f "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam.bai" ]] ||
        die "Normal realigned BAM index was not created."

fi


# -----------------------------------------------------------------------------
# Cleanup intermediate files that are no longer required.
# -----------------------------------------------------------------------------

rm -f \
    "${REALIGN_DIR}"/*.filtered.bam \
    "${REALIGN_DIR}"/*.filtered.bam.bai \
    "${REALIGN_DIR}"/*_read_names.txt \
    "${REALIGN_DIR}"/*.fastq.gz


# =============================================================================
# Stage 5 - Final Mutect2
# =============================================================================

echo ""
echo "============================================================"
echo "[STAGE 5/5] Final variant re-calling"
echo "============================================================"


if [[ -n "${DNA_BAM_PATH}" ]]; then

    echo ""
    echo "--> Final Mutect2 in matched-normal mode..."


    gatk Mutect2 \
        -R "${REFERENCE_FASTA}" \
        -I "${REALIGN_DIR}/${BASENAME}.realigned.bam" \
        -I "${REALIGN_DIR}/${NORMAL_SAMPLE_NAME}.realigned.bam" \
        -normal "${NORMAL_SAMPLE_NAME}" \
        -L "${REALIGN_DIR}/variants.interval_list" \
        --germline-resource "${GERMLINE_RESOURCE}" \
        --panel-of-normals "${PANEL_OF_NORMALS}" \
        -O "${FINAL_VCF_OUT}"

else

    echo ""
    echo "--> Final Mutect2 in tumor-only mode..."


    gatk Mutect2 \
        -R "${REFERENCE_FASTA}" \
        -I "${REALIGN_DIR}/${BASENAME}.realigned.bam" \
        -L "${REALIGN_DIR}/variants.interval_list" \
        --germline-resource "${GERMLINE_RESOURCE}" \
        --panel-of-normals "${PANEL_OF_NORMALS}" \
        -O "${FINAL_VCF_OUT}"

fi


# =============================================================================
# Validate final output
# =============================================================================

[[ -f "${FINAL_VCF_OUT}" ]] ||
    die "Final Mutect2 VCF was not created."


if [[ ! -f "${FINAL_VCF_OUT}.tbi" &&
      ! -f "${FINAL_VCF_OUT}.csi" ]]; then

    echo ""
    echo "Final VCF index was not found; creating TBI index..."

    gatk IndexFeatureFile \
        -I "${FINAL_VCF_OUT}"

fi


# =============================================================================
# Completion
# =============================================================================

echo ""
echo "============================================================"
echo "RNA-MuTect pipeline completed successfully."
echo "============================================================"

echo ""
echo "Output directory:"
echo "  ${OUTPUT_DIR}"

echo ""
echo "Main annotated MAF:"
echo "  ${FUNCOMAF}"

echo ""
echo "Merged initial Mutect2 VCF:"
echo "  ${MERGED_VCF}"

echo ""
echo "Final re-aligned Mutect2 VCF:"
echo "  ${FINAL_VCF_OUT}"

echo ""
echo "Final re-aligned BAM:"
echo "  ${REALIGN_DIR}/${BASENAME}.realigned.bam"

echo ""
echo "HISAT2 alignment summary:"
echo "  ${REALIGN_DIR}/${BASENAME}.hisat2.summary.txt"

echo ""
echo "Pipeline status:"
echo "  SUCCESS"

echo ""

date
