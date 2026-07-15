#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  merge_validated_fastqs.sh VALIDATION_TSV TEMP_OUTPUT_DIR

Example:
  ./merge_validated_fastqs.sh \
    ena_submission/outputs/validation_outcome_v6.tsv \
    /cluster/work/users/anba/ena_tmp_fastqs

The validation TSV must contain:
  status
  library_key
  resolved_barcode_dir

Only rows where status is exactly OK are processed.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

[[ $# -eq 2 ]] || { usage; exit 2; }

VALIDATION_FILE=$1
TEMP_OUTPUT_DIR=$2

[[ -r "$VALIDATION_FILE" ]] || die "Cannot read validation file: $VALIDATION_FILE"
mkdir -p "$TEMP_OUTPUT_DIR"
[[ -d "$TEMP_OUTPUT_DIR" ]] || die "Cannot create output directory: $TEMP_OUTPUT_DIR"

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

for required in status library_key resolved_barcode_dir; do
    column_exists "$required" || die "Missing required column: $required"
done

STATUS_IDX=$(field_index status)
LIBRARY_IDX=$(field_index library_key)
BARCODE_DIR_IDX=$(field_index resolved_barcode_dir)

SUMMARY_FILE="${TEMP_OUTPUT_DIR%/}/merge_summary.tsv"
printf 'library_key\tmerged_fastq\tsource_file_count\tmerged_size_bytes\tstatus\n' > "$SUMMARY_FILE"

declare -A SEEN_LIBRARIES

created=0
skipped=0
failed=0
line_no=0

while IFS=$'\t' read -r -a FIELDS || [[ ${#FIELDS[@]} -gt 0 ]]; do
    line_no=$((line_no + 1))
    [[ "$line_no" -eq 1 ]] && continue

    joined="${FIELDS[*]:-}"
    [[ -z "${joined//[[:space:]]/}" ]] && continue

    status=${FIELDS[$STATUS_IDX]:-}
    library_key=${FIELDS[$LIBRARY_IDX]:-}
    barcode_dir=${FIELDS[$BARCODE_DIR_IDX]:-}

    status=${status%$'\r'}
    library_key=${library_key%$'\r'}
    barcode_dir=${barcode_dir%$'\r'}

    if [[ "$status" != "OK" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    if [[ -z "$library_key" || -z "$barcode_dir" ]]; then
        echo "FAIL line $line_no: empty library_key or barcode directory" >&2
        printf '%s\t\t0\t0\tFAILED\n' "$library_key" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi

    if [[ -n "${SEEN_LIBRARIES[$library_key]+x}" ]]; then
        echo "FAIL line $line_no: duplicate library_key '$library_key'" >&2
        printf '%s\t\t0\t0\tFAILED_DUPLICATE_LIBRARY\n' "$library_key" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi
    SEEN_LIBRARIES["$library_key"]=1

    [[ -d "$barcode_dir" ]] || {
        echo "FAIL: barcode directory missing: $barcode_dir" >&2
        printf '%s\t\t0\t0\tFAILED_MISSING_DIRECTORY\n' "$library_key" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    }

    safe_library_name=$(printf '%s' "$library_key" | sed 's/[^A-Za-z0-9._-]/_/g')
    merged_fastq="${TEMP_OUTPUT_DIR%/}/${safe_library_name}.fastq.gz"

    if [[ -e "$merged_fastq" ]]; then
        echo "FAIL: output already exists: $merged_fastq" >&2
        printf '%s\t%s\t0\t0\tFAILED_EXISTS\n' "$library_key" "$merged_fastq" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi

    mapfile -d '' source_files < <(
        find "$barcode_dir" -type f \
            \( -iname '*.fastq.gz' -o -iname '*.fq.gz' \) \
            -print0 | sort -z
    )

    if [[ ${#source_files[@]} -eq 0 ]]; then
        echo "FAIL: no compressed FASTQ files found for $library_key" >&2
        printf '%s\t\t0\t0\tFAILED_NO_FILES\n' "$library_key" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi

    echo "Merging ${#source_files[@]} files for $library_key"

    if cat "${source_files[@]}" > "$merged_fastq"; then
        if gzip -t "$merged_fastq"; then
            merged_size=$(stat -c '%s' "$merged_fastq")
            printf '%s\t%s\t%s\t%s\tOK\n' \
                "$library_key" "$merged_fastq" "${#source_files[@]}" "$merged_size" \
                >> "$SUMMARY_FILE"
            echo "CREATED: $merged_fastq"
            created=$((created + 1))
        else
            echo "FAIL: gzip integrity test failed for $merged_fastq" >&2
            rm -f "$merged_fastq"
            printf '%s\t%s\t%s\t0\tFAILED_GZIP_TEST\n' \
                "$library_key" "$merged_fastq" "${#source_files[@]}" \
                >> "$SUMMARY_FILE"
            failed=$((failed + 1))
        fi
    else
        echo "FAIL: concatenation failed for $library_key" >&2
        rm -f "$merged_fastq"
        printf '%s\t%s\t%s\t0\tFAILED_CAT\n' \
            "$library_key" "$merged_fastq" "${#source_files[@]}" \
            >> "$SUMMARY_FILE"
        failed=$((failed + 1))
    fi

done < "$VALIDATION_FILE"

echo
echo "Merge complete"
echo "  Created: $created"
echo "  Skipped: $skipped"
echo "  Failed: $failed"
echo "  Summary: $SUMMARY_FILE"

(( failed == 0 )) || exit 1
(( created > 0 )) || exit 1
