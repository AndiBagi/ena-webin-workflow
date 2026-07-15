#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
Usage:
  Interactive:
    validate_nanopore_metadata_flexible_v5.sh \
      METADATA_TSV ROOT_DIR ENA_SAMPLES_CSV [REPORT_TSV]

  Non-interactive:
    validate_nanopore_metadata_flexible_v5.sh \
      METADATA_TSV ROOT_DIR ENA_SAMPLES_CSV REPORT_TSV \
      SAMPLE_ALIAS_COLUMN LIBRARY_KEY_COLUMN BARCODE_COLUMN PATH_COLUMNS

PATH_COLUMNS is a comma-separated ordered list of metadata columns used below ROOT_DIR.

Examples:

Simple layout:
  ROOT/run_accession/fastq_pass/barcode
  PATH_COLUMNS="run_accession"

Nested layout:
  ROOT/run_name/sample_name/run_accession/fastq_pass/barcode
  PATH_COLUMNS="run_name,sample_name,run_accession"

ENA sample validation:
  The value selected as SAMPLE_ALIAS_COLUMN must match the "alias" column
  in the ENA sample export. The matching ENA "id" value is recorded and
  will later map to SAMPLE in the ENA manifest.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

[[ $# -ge 3 ]] || { usage; exit 2; }

METADATA_FILE=$1
ROOT_DIR=$2
ENA_SAMPLES_FILE=$3
REPORT_FILE=${4:-nanopore_validation_report.tsv}

[[ -r "$METADATA_FILE" ]] || die "Cannot read metadata file: $METADATA_FILE"
[[ -d "$ROOT_DIR" ]] || die "Root directory does not exist: $ROOT_DIR"
[[ -r "$ENA_SAMPLES_FILE" ]] || die "Cannot read ENA sample list: $ENA_SAMPLES_FILE"
command -v python3 >/dev/null 2>&1 || die "python3 is required to parse the ENA CSV file."

if [[ "$ROOT_DIR" != "/" ]]; then
    ROOT_DIR="${ROOT_DIR%/}"
fi

HEADER=$(head -n 1 "$METADATA_FILE" | tr -d '\r')
IFS=$'\t' read -r -a COLUMNS <<< "$HEADER"

echo "Available metadata columns:"
printf '  %s\n' "${COLUMNS[@]}"
echo

column_exists() {
    local wanted=$1
    local col
    for col in "${COLUMNS[@]}"; do
        [[ "$col" == "$wanted" ]] && return 0
    done
    return 1
}

if [[ $# -ge 8 ]]; then
    SAMPLE_ALIAS_COLUMN=$5
    LIBRARY_KEY_COLUMN=$6
    BARCODE_COLUMN=$7
    PATH_COLUMNS_CSV=$8
else
    read -r -p "Column whose values match ENA sample aliases [sample_key or sample]: " SAMPLE_ALIAS_COLUMN
    SAMPLE_ALIAS_COLUMN=${SAMPLE_ALIAS_COLUMN:-sample_key}

    if ! column_exists "$SAMPLE_ALIAS_COLUMN" && column_exists "sample"; then
        SAMPLE_ALIAS_COLUMN="sample"
        echo "Using fallback column: sample"
    fi

    read -r -p "Column mapping to NAME and LIBRARY_NAME [library_key or sample]: " LIBRARY_KEY_COLUMN
    LIBRARY_KEY_COLUMN=${LIBRARY_KEY_COLUMN:-library_key}

    if ! column_exists "$LIBRARY_KEY_COLUMN" && column_exists "sample"; then
        LIBRARY_KEY_COLUMN="sample"
        echo "Using fallback column: sample"
    fi

    read -r -p "Barcode column [barcode]: " BARCODE_COLUMN
    BARCODE_COLUMN=${BARCODE_COLUMN:-barcode}

    echo
    echo "Enter ordered metadata columns forming the path below ROOT_DIR."
    echo "Examples:"
    echo "  accession"
    echo "  run_accession"
    echo "  run_name,sample_name,run_accession"
    read -r -p "Path columns: " PATH_COLUMNS_CSV
fi

[[ -n "$PATH_COLUMNS_CSV" ]] || die "At least one path-building column is required."

IFS=',' read -r -a PATH_COLUMNS <<< "$PATH_COLUMNS_CSV"

for col in "$SAMPLE_ALIAS_COLUMN" "$LIBRARY_KEY_COLUMN" "$BARCODE_COLUMN" "${PATH_COLUMNS[@]}"; do
    column_exists "$col" || die "Column '$col' was not found in the metadata header."
done

field_index() {
    local wanted=$1
    local i
    for i in "${!COLUMNS[@]}"; do
        if [[ "${COLUMNS[$i]}" == "$wanted" ]]; then
            echo $((i + 1))
            return 0
        fi
    done
    return 1
}

SAMPLE_IDX=$(field_index "$SAMPLE_ALIAS_COLUMN")
LIBRARY_IDX=$(field_index "$LIBRARY_KEY_COLUMN")
BARCODE_IDX=$(field_index "$BARCODE_COLUMN")

PATH_INDICES=()
for col in "${PATH_COLUMNS[@]}"; do
    PATH_INDICES+=("$(field_index "$col")")
done

# Parse the ENA CSV safely, including quoted fields.
ENA_LOOKUP=$(mktemp)
trap 'rm -f "$ENA_LOOKUP"' EXIT

python3 - "$ENA_SAMPLES_FILE" "$ENA_LOOKUP" <<'PY'
import csv
import sys
from collections import defaultdict

source, output = sys.argv[1], sys.argv[2]
rows_by_alias = defaultdict(list)

with open(source, newline="", encoding="utf-8-sig") as handle:
    reader = csv.DictReader(handle)
    fields = reader.fieldnames or []
    missing = [name for name in ("alias", "id") if name not in fields]
    if missing:
        raise SystemExit(
            "ERROR: ENA sample CSV is missing required column(s): "
            + ", ".join(missing)
        )

    for row in reader:
        alias = (row.get("alias") or "").strip()
        accession = (row.get("id") or "").strip()
        if alias:
            rows_by_alias[alias].append(accession)

with open(output, "w", encoding="utf-8", newline="") as handle:
    for alias, accessions in rows_by_alias.items():
        nonempty = sorted({x for x in accessions if x})
        if len(accessions) > 1:
            state = "DUPLICATE_ALIAS"
        elif not nonempty:
            state = "MISSING_ID"
        else:
            state = "OK"
        handle.write(f"{alias}\t{','.join(nonempty)}\t{state}\n")
PY

[[ $? -eq 0 ]] || die "Failed to parse ENA sample CSV."

declare -A ENA_IDS
declare -A ENA_STATES

while IFS=$'\t' read -r alias accession state; do
    ENA_IDS["$alias"]=$accession
    ENA_STATES["$alias"]=$state
done < "$ENA_LOOKUP"

mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null || true

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "line_number" \
    "sample_alias" \
    "ena_sample_accession" \
    "ena_alias_status" \
    "library_key" \
    "barcode" \
    "resolved_barcode_dir" \
    "relative_barcode_dir" \
    "fastq_count" \
    "fastq_total_bytes" \
    "fastq_total_size" \
    "status" \
    "details" \
    "path_components" > "$REPORT_FILE"

declare -A SEEN_LIBRARY_KEYS
declare -A SEEN_PATH_BARCODE

TOTAL=0
FAILED=0
PASSED=0
LINE_NO=0

while IFS=$'\t' read -r -a FIELDS || [[ ${#FIELDS[@]} -gt 0 ]]; do
    LINE_NO=$((LINE_NO + 1))
    [[ $LINE_NO -eq 1 ]] && continue

    joined="${FIELDS[*]:-}"
    [[ -z "${joined//[[:space:]]/}" ]] && continue

    TOTAL=$((TOTAL + 1))

    sample_alias=${FIELDS[$((SAMPLE_IDX - 1))]:-}
    library_key=${FIELDS[$((LIBRARY_IDX - 1))]:-}
    barcode=${FIELDS[$((BARCODE_IDX - 1))]:-}

    sample_alias=${sample_alias%$'\r'}
    library_key=${library_key%$'\r'}
    barcode=${barcode%$'\r'}

    status="OK"
    details=()
    ena_sample_accession=""
    ena_alias_status="NOT_FOUND"

    [[ -n "$sample_alias" ]] || { status="FAIL"; details+=("empty sample alias"); }
    [[ -n "$library_key" ]] || { status="FAIL"; details+=("empty library key"); }
    [[ -n "$barcode" ]] || { status="FAIL"; details+=("empty barcode"); }

    if [[ -n "$sample_alias" ]]; then
        if [[ -z "${ENA_STATES[$sample_alias]+x}" ]]; then
            status="FAIL"
            details+=("sample alias absent from ENA sample list")
        else
            ena_alias_status=${ENA_STATES[$sample_alias]}
            ena_sample_accession=${ENA_IDS[$sample_alias]}

            case "$ena_alias_status" in
                OK)
                    if [[ ! "$ena_sample_accession" =~ ^ERS[0-9]+$ ]]; then
                        status="FAIL"
                        details+=("ENA id is missing or not an ERS accession")
                    fi
                    ;;
                MISSING_ID)
                    status="FAIL"
                    details+=("ENA alias has no id")
                    ;;
                DUPLICATE_ALIAS)
                    status="FAIL"
                    details+=("ENA alias occurs more than once")
                    ;;
            esac
        fi
    fi

    if [[ -n "$barcode" && ! "$barcode" =~ ^barcode[0-9]+$ ]]; then
        status="FAIL"
        details+=("unexpected barcode format")
    fi

    if [[ -n "$library_key" ]]; then
        if [[ -n "${SEEN_LIBRARY_KEYS[$library_key]+x}" ]]; then
            status="FAIL"
            details+=("duplicate library key")
        else
            SEEN_LIBRARY_KEYS["$library_key"]=1
        fi
    fi

    path="$ROOT_DIR"
    path_component_values=()
    missing_path_component=0

    for idx in "${PATH_INDICES[@]}"; do
        value=${FIELDS[$((idx - 1))]:-}
        value=${value%$'\r'}
        path_component_values+=("$value")

        if [[ -z "$value" ]]; then
            missing_path_component=1
            status="FAIL"
            details+=("empty path component")
        else
            path+="/$value"
        fi
    done

    barcode_dir="$path/fastq_pass/$barcode"

    if [[ "$ROOT_DIR" == "/" ]]; then
        relative_barcode_dir="${barcode_dir#/}"
    elif [[ "$barcode_dir" == "$ROOT_DIR/"* ]]; then
        relative_barcode_dir="${barcode_dir#"$ROOT_DIR"/}"
    else
        relative_barcode_dir=""
        status="FAIL"
        details+=("resolved barcode directory is outside ROOT_DIR")
    fi

    path_barcode_key="${path}|${barcode}"

    if [[ -n "${SEEN_PATH_BARCODE[$path_barcode_key]+x}" ]]; then
        status="FAIL"
        details+=("duplicate path+barcode mapping")
    else
        SEEN_PATH_BARCODE["$path_barcode_key"]=1
    fi

    fastq_count=0
    fastq_total_bytes=0
    fastq_total_size="0 B"

    if [[ $missing_path_component -eq 0 ]]; then
        if [[ ! -d "$path" ]]; then
            status="FAIL"
            details+=("run path missing")
        elif [[ ! -d "$path/fastq_pass" ]]; then
            status="FAIL"
            details+=("fastq_pass missing")
        elif [[ ! -d "$barcode_dir" ]]; then
            status="FAIL"
            details+=("barcode folder missing")
        else
            fastq_count=$(
                find "$barcode_dir" -type f \
                    \( -iname '*.fastq' -o -iname '*.fastq.gz' \
                       -o -iname '*.fq' -o -iname '*.fq.gz' \) \
                    -print 2>/dev/null | wc -l
            )

            fastq_total_bytes=$(
                find "$barcode_dir" -type f \
                    \( -iname '*.fastq' -o -iname '*.fastq.gz' \
                       -o -iname '*.fq' -o -iname '*.fq.gz' \) \
                    -printf '%s\n' 2>/dev/null \
                | awk '{sum += $1} END {print sum + 0}'
            )

            if command -v numfmt >/dev/null 2>&1; then
                fastq_total_size=$(numfmt --to=iec-i --suffix=B "$fastq_total_bytes")
            else
                fastq_total_size="${fastq_total_bytes} B"
            fi

            if [[ "$fastq_count" -eq 0 ]]; then
                status="FAIL"
                details+=("no FASTQ files")
            fi
        fi
    fi

    if [[ "$status" == "OK" ]]; then
        PASSED=$((PASSED + 1))
        detail_text="validated"
    else
        FAILED=$((FAILED + 1))
        detail_text=$(IFS='; '; echo "${details[*]}")
    fi

    path_values_text=$(IFS='/'; echo "${path_component_values[*]}")

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$LINE_NO" \
        "$sample_alias" \
        "$ena_sample_accession" \
        "$ena_alias_status" \
        "$library_key" \
        "$barcode" \
        "$barcode_dir" \
        "$relative_barcode_dir" \
        "$fastq_count" \
        "$fastq_total_bytes" \
        "$fastq_total_size" \
        "$status" \
        "$detail_text" \
        "$path_values_text" >> "$REPORT_FILE"

done < "$METADATA_FILE"

echo
echo "Validation complete"
echo "  Metadata file: $METADATA_FILE"
echo "  ENA sample list: $ENA_SAMPLES_FILE"
echo "  Root directory: $ROOT_DIR"
echo "  Path layout: ROOT/${PATH_COLUMNS_CSV//,/\/}/fastq_pass/$BARCODE_COLUMN"
echo "  Total rows: $TOTAL"
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo "  Report: $REPORT_FILE"

if [[ "$FAILED" -gt 0 ]]; then
    echo "RESULT: FAILED — inspect rows marked FAIL in the report."
    exit 1
fi

echo "RESULT: PASSED — filesystem and ENA sample mappings are valid."
exit 0
