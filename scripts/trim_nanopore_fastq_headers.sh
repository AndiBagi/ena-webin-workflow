#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Trim Nanopore FASTQ headers to the original read ID and safely replace the files.

Usage:
  trim_nanopore_fastq_headers.sh MERGED_FASTQ_DIR

Example:
  ./trim_nanopore_fastq_headers.sh \
    /cluster/work/users/anba/ena_submission_susoffaqua_odin/data/ena_tmp_fastqs

Header transformation:

Before:
  @79e76f91-52ed-4448-bbdc-383232547b26 runid=... barcode=barcode01 ...

After:
  @79e76f91-52ed-4448-bbdc-383232547b26

The script:
  - processes *.fastq.gz and *.fq.gz files
  - preserves the original Nanopore read ID
  - removes only the metadata after the first whitespace
  - writes a temporary file in the same directory
  - checks gzip integrity and FASTQ structure
  - replaces the original file only after validation succeeds
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

[[ $# -eq 1 ]] || { usage; exit 2; }

FASTQ_DIR=${1%/}

[[ -d "$FASTQ_DIR" ]] || die "Directory does not exist: $FASTQ_DIR"
command -v gzip >/dev/null 2>&1 || die "gzip not found."
command -v awk >/dev/null 2>&1 || die "awk not found."

shopt -s nullglob
files=("$FASTQ_DIR"/*.fastq.gz "$FASTQ_DIR"/*.fq.gz)

if (( ${#files[@]} == 0 )); then
    die "No .fastq.gz or .fq.gz files found in: $FASTQ_DIR"
fi

SUMMARY_FILE="$FASTQ_DIR/header_trim_summary.tsv"
printf 'file\trecords\tstatus\n' > "$SUMMARY_FILE"

updated=0
failed=0

for fastq in "${files[@]}"; do
    filename=$(basename "$fastq")
    tmp="${fastq}.trim_tmp.$$"
    count_file="${fastq}.record_count_tmp.$$"

    echo "Processing: $filename"

    if gzip -cd -- "$fastq" |
        awk -v count_file="$count_file" '
            NR % 4 == 1 {
                ++n
                # $1 is the first whitespace-delimited token, including the leading @.
                print $1
                next
            }
            { print }
            END {
                print n + 0 > count_file
            }
        ' |
        gzip -c > "$tmp"
    then
        :
    else
        echo "FAILED: rewrite failed for $filename" >&2
        rm -f "$tmp" "$count_file"
        printf '%s\t0\tFAILED_REWRITE\n' "$filename" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi

    record_count=$(cat "$count_file" 2>/dev/null || echo 0)
    rm -f "$count_file"

    if ! gzip -t "$tmp"; then
        echo "FAILED: gzip integrity test failed for $filename" >&2
        rm -f "$tmp"
        printf '%s\t%s\tFAILED_GZIP_TEST\n' \
            "$filename" "$record_count" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi

    if ! gzip -cd -- "$tmp" |
        awk '
            NR % 4 == 1 {
                if (substr($0, 1, 1) != "@") bad=1
                if (length($0) > 256) bad=1
                if ($0 ~ /[[:space:]]/) bad=1
            }
            NR % 4 == 2 {
                seq_len=length($0)
            }
            NR % 4 == 3 {
                if (substr($0, 1, 1) != "+") bad=1
            }
            NR % 4 == 0 {
                if (length($0) != seq_len) bad=1
            }
            END {
                if (NR % 4 != 0) bad=1
                exit bad
            }
        '
    then
        echo "FAILED: FASTQ validation failed for $filename" >&2
        rm -f "$tmp"
        printf '%s\t%s\tFAILED_FASTQ_VALIDATION\n' \
            "$filename" "$record_count" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
        continue
    fi

    chmod --reference="$fastq" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$fastq"

    echo "UPDATED: $filename ($record_count records)"
    printf '%s\t%s\tOK\n' \
        "$filename" "$record_count" >> "$SUMMARY_FILE"
    updated=$((updated + 1))
done

echo
echo "Header trimming complete"
echo "  Updated: $updated"
echo "  Failed: $failed"
echo "  Summary: $SUMMARY_FILE"

(( failed == 0 )) || exit 1
