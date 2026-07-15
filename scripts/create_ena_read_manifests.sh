#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  create_ena_read_manifests_v3.sh VALIDATION_TSV ROOT_DIR

The script can create manifests using either:
  1. Original validated barcode FASTQs
  2. One merged FASTQ per library

For merged mode, the user is prompted for the merged FASTQ directory.

Output:
  ROOT_DIR/ena_submission/outputs/manifest_files/
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

[[ $# -eq 2 ]] || { usage; exit 2; }

VALIDATION_FILE=$1
ROOT_DIR=$2

[[ -r "$VALIDATION_FILE" ]] || die "Cannot read validation file: $VALIDATION_FILE"
[[ -d "$ROOT_DIR" ]] || die "Root directory does not exist: $ROOT_DIR"

ROOT_DIR="${ROOT_DIR%/}"
MANIFEST_DIR="${ROOT_DIR}/ena_submission/outputs/manifest_files"
mkdir -p "$MANIFEST_DIR"

HEADER=$(head -n 1 "$VALIDATION_FILE" | tr -d '\r')
IFS=$'\t' read -r -a COLUMNS <<< "$HEADER"

column_exists() {
    local wanted=$1
    local column
    for column in "${COLUMNS[@]}"; do
        [[ "$column" == "$wanted" ]] && return 0
    done
    return 1
}

field_index() {
    local wanted=$1
    local i
    for i in "${!COLUMNS[@]}"; do
        if [[ "${COLUMNS[$i]}" == "$wanted" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

for required in status ena_sample_accession library_key resolved_barcode_dir relative_barcode_dir; do
    column_exists "$required" || die "Missing required column: $required"
done

STATUS_IDX=$(field_index status)
SAMPLE_IDX=$(field_index ena_sample_accession)
LIBRARY_IDX=$(field_index library_key)
ABS_DIR_IDX=$(field_index resolved_barcode_dir)
REL_DIR_IDX=$(field_index relative_barcode_dir)

echo "Choose FASTQ source:"
echo "  1: Original validated barcode FASTQs"
echo "  2: One merged FASTQ per library"
while true; do
    read -r -p "Choice [1-2]: " FASTQ_MODE
    [[ "$FASTQ_MODE" == "1" || "$FASTQ_MODE" == "2" ]] && break
    echo "Please enter 1 or 2."
done

MERGED_FASTQ_DIR=""
if [[ "$FASTQ_MODE" == "2" ]]; then
    while true; do
        read -r -p "Directory containing merged FASTQs: " MERGED_FASTQ_DIR
        [[ -d "$MERGED_FASTQ_DIR" ]] && break
        echo "Directory does not exist."
    done
    MERGED_FASTQ_DIR="${MERGED_FASTQ_DIR%/}"
fi

read -r -p "Include INSERT_SIZE? [y/N]: " INCLUDE_INSERT
INCLUDE_INSERT=${INCLUDE_INSERT:-N}
INSERT_SIZE=""
if [[ "$INCLUDE_INSERT" =~ ^[Yy]$ ]]; then
    while true; do
        read -r -p "Insert size in bases: " INSERT_SIZE
        [[ "$INSERT_SIZE" =~ ^[1-9][0-9]*$ ]] && break
        echo "Enter a positive integer."
    done
fi

read -r -p "Include DESCRIPTION? [y/N]: " INCLUDE_DESCRIPTION
INCLUDE_DESCRIPTION=${INCLUDE_DESCRIPTION:-N}
DESCRIPTION=""
if [[ "$INCLUDE_DESCRIPTION" =~ ^[Yy]$ ]]; then
    while [[ -z "$DESCRIPTION" ]]; do
        read -r -p "Library description: " DESCRIPTION
    done
fi

while true; do
    read -r -p "ENA study accession (STUDY): " STUDY
    [[ -n "$STUDY" ]] && break
done

echo "Choose PLATFORM:"
echo "  1: OXFORD_NANOPORE"
echo "  2: ILLUMINA"
while true; do
    read -r -p "Choice [1-2]: " choice
    case "$choice" in
        1) PLATFORM="OXFORD_NANOPORE"; break ;;
        2) PLATFORM="ILLUMINA"; break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done

echo "Choose INSTRUMENT:"
echo "  1: MinION"
echo "  2: Illumina NovaSeq 6000"
while true; do
    read -r -p "Choice [1-2]: " choice
    case "$choice" in
        1) INSTRUMENT="MinION"; break ;;
        2) INSTRUMENT="Illumina NovaSeq 6000"; break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done

read -r -p "LIBRARY_SOURCE [METAGENOMIC]: " LIBRARY_SOURCE
LIBRARY_SOURCE=${LIBRARY_SOURCE:-METAGENOMIC}

echo "Choose LIBRARY_SELECTION:"
echo "  1: RANDOM"
echo "  2: PCR"
while true; do
    read -r -p "Choice [1-2]: " choice
    case "$choice" in
        1) LIBRARY_SELECTION="RANDOM"; break ;;
        2) LIBRARY_SELECTION="PCR"; break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done

echo "Choose LIBRARY_STRATEGY:"
echo "  1: WGS"
echo "  2: AMPLICON"
while true; do
    read -r -p "Choice [1-2]: " choice
    case "$choice" in
        1) LIBRARY_STRATEGY="WGS"; break ;;
        2) LIBRARY_STRATEGY="AMPLICON"; break ;;
        *) echo "Please enter 1 or 2." ;;
    esac
done

echo
echo "Manifest settings"
echo "-----------------"
printf '%-20s %s\n' "FASTQ mode" "$FASTQ_MODE"
printf '%-20s %s\n' "STUDY" "$STUDY"
printf '%-20s %s\n' "PLATFORM" "$PLATFORM"
printf '%-20s %s\n' "INSTRUMENT" "$INSTRUMENT"
printf '%-20s %s\n' "LIBRARY_SOURCE" "$LIBRARY_SOURCE"
printf '%-20s %s\n' "LIBRARY_SELECTION" "$LIBRARY_SELECTION"
printf '%-20s %s\n' "LIBRARY_STRATEGY" "$LIBRARY_STRATEGY"
printf '%-20s %s\n' "INSERT_SIZE" "${INSERT_SIZE:-(not used)}"
printf '%-20s %s\n' "DESCRIPTION" "${DESCRIPTION:-(not used)}"
printf '%-20s %s\n' "OUTPUT_DIR" "$MANIFEST_DIR"
[[ "$FASTQ_MODE" == "2" ]] && printf '%-20s %s\n' "MERGED_FASTQ_DIR" "$MERGED_FASTQ_DIR"

read -r -p "Proceed? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Cancelled."

declare -A SEEN_LIBRARIES
created=0
failed=0
line_no=0

while IFS=$'\t' read -r -a FIELDS || [[ ${#FIELDS[@]} -gt 0 ]]; do
    line_no=$((line_no + 1))
    [[ "$line_no" -eq 1 ]] && continue

    joined="${FIELDS[*]:-}"
    [[ -z "${joined//[[:space:]]/}" ]] && continue

    status=${FIELDS[$STATUS_IDX]:-}
    sample_accession=${FIELDS[$SAMPLE_IDX]:-}
    library_key=${FIELDS[$LIBRARY_IDX]:-}
    absolute_barcode_dir=${FIELDS[$ABS_DIR_IDX]:-}
    relative_barcode_dir=${FIELDS[$REL_DIR_IDX]:-}

    status=${status%$'\r'}
    sample_accession=${sample_accession%$'\r'}
    library_key=${library_key%$'\r'}
    absolute_barcode_dir=${absolute_barcode_dir%$'\r'}
    relative_barcode_dir=${relative_barcode_dir%$'\r'}

    [[ "$status" == "OK" ]] || continue

    if [[ -n "${SEEN_LIBRARIES[$library_key]+x}" ]]; then
        echo "FAIL: duplicate library_key $library_key" >&2
        failed=$((failed + 1))
        continue
    fi
    SEEN_LIBRARIES["$library_key"]=1

    safe_library_name=$(printf '%s' "$library_key" | sed 's/[^A-Za-z0-9._-]/_/g')
    manifest_file="${MANIFEST_DIR}/manifest_${safe_library_name}"

    FASTQ_ENTRIES=()

    if [[ "$FASTQ_MODE" == "1" ]]; then
        mapfile -d '' files < <(
            find "$absolute_barcode_dir" -type f \
                \( -iname '*.fastq' -o -iname '*.fastq.gz' -o -iname '*.fq' -o -iname '*.fq.gz' \) \
                -print0 | sort -z
        )

        if (( ${#files[@]} == 0 )); then
            echo "FAIL: no FASTQs for $library_key" >&2
            failed=$((failed + 1))
            continue
        fi

        if (( ${#files[@]} > 10 )); then
            echo "FAIL: $library_key has ${#files[@]} FASTQs; ENA allows at most 10. Use merged mode." >&2
            failed=$((failed + 1))
            continue
        fi

        for file in "${files[@]}"; do
            FASTQ_ENTRIES+=("${file#"$ROOT_DIR"/}")
        done
    else
        merged_fastq="${MERGED_FASTQ_DIR}/${safe_library_name}.fastq.gz"

        if [[ ! -r "$merged_fastq" ]]; then
            echo "FAIL: merged FASTQ missing: $merged_fastq" >&2
            failed=$((failed + 1))
            continue
        fi

        # In merged mode, Webin-CLI should receive MERGED_FASTQ_DIR as -inputDir.
        # Therefore, store only the FASTQ filename in the manifest.
        FASTQ_ENTRIES+=("$(basename "$merged_fastq")")
    fi

    {
        printf 'STUDY:\t%s\n' "$STUDY"
        printf 'SAMPLE:\t%s\n' "$sample_accession"
        printf 'NAME:\t%s\n' "$library_key"
        printf 'PLATFORM:\t%s\n' "$PLATFORM"
        printf 'INSTRUMENT:\t%s\n' "$INSTRUMENT"
        [[ -n "$INSERT_SIZE" ]] && printf 'INSERT_SIZE:\t%s\n' "$INSERT_SIZE"
        printf 'LIBRARY_NAME:\t%s\n' "$library_key"
        printf 'LIBRARY_SOURCE:\t%s\n' "$LIBRARY_SOURCE"
        printf 'LIBRARY_SELECTION:\t%s\n' "$LIBRARY_SELECTION"
        printf 'LIBRARY_STRATEGY:\t%s\n' "$LIBRARY_STRATEGY"
        [[ -n "$DESCRIPTION" ]] && printf 'DESCRIPTION:\t%s\n' "$DESCRIPTION"
        for fastq in "${FASTQ_ENTRIES[@]}"; do
            printf 'FASTQ:\t%s\n' "$fastq"
        done
    } > "$manifest_file"

    echo "CREATED: $manifest_file"
    created=$((created + 1))

done < "$VALIDATION_FILE"

echo
echo "Created: $created"
echo "Failed: $failed"
echo "Manifest directory: $MANIFEST_DIR"

(( failed == 0 )) || exit 1
(( created > 0 )) || exit 1
