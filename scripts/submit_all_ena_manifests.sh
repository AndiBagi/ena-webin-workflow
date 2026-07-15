#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
Submit all ENA read manifests with Webin-CLI.

Usage:
  ./submit_all_ena_manifests.sh

Optional KEY=VALUE overrides:
  ./submit_all_ena_manifests.sh \
    ROOT_DIR="/path/to/project/root" \
    INPUT_DIR="/path/to/merged_fastqs" \
    WEBIN_JAR="/path/to/webin-cli.jar"

Supported overrides:
  ROOT_DIR
  WEBIN_JAR
  WEBIN_USER
  WEBIN_PASSWORD
  MANIFEST_DIR
  INPUT_DIR
  BASE_OUTPUT_DIR
  LOG_FILE

This script uses Webin-CLI -submit.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}


# Load the correct java module
module load Java/17.0.17


for arg in "$@"; do
    case "$arg" in
        *=*)
            key=${arg%%=*}
            value=${arg#*=}

            case "$key" in
                ROOT_DIR|WEBIN_JAR|WEBIN_USER|WEBIN_PASSWORD|\
                MANIFEST_DIR|INPUT_DIR|BASE_OUTPUT_DIR|LOG_FILE)
                    export "$key=$value"
                    ;;
                *)
                    die "Unsupported override variable: $key"
                    ;;
            esac
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Arguments must use KEY=VALUE syntax: $arg"
            ;;
    esac
done

ROOT_DIR="${ROOT_DIR:-/NORCE/Data/400/40010/104456-SusOffAqua/WP1/anba/02_nanopore_16S_exp}"
ROOT_DIR="${ROOT_DIR%/}"

WEBIN_JAR="${WEBIN_JAR:-webin-cli-9.0.1.jar}"

MANIFEST_DIR="${MANIFEST_DIR:-${ROOT_DIR}/ena_submission/outputs/manifest_files}"
INPUT_DIR="${INPUT_DIR:-${ROOT_DIR}}"
BASE_OUTPUT_DIR="${BASE_OUTPUT_DIR:-${ROOT_DIR}/ena_submission/outputs/webin_submission}"
LOG_FILE="${LOG_FILE:-${BASE_OUTPUT_DIR}/webin_cli_submission_all.log}"

[[ -r "$WEBIN_JAR" ]] ||
    die "Webin-CLI JAR cannot be read: $WEBIN_JAR"

[[ -d "$MANIFEST_DIR" ]] ||
    die "Manifest directory does not exist: $MANIFEST_DIR"

[[ -d "$INPUT_DIR" ]] ||
    die "Input directory does not exist: $INPUT_DIR"

command -v java >/dev/null 2>&1 ||
    die "Java was not found in PATH."

JAVA_VERSION_LINE=$(java -version 2>&1 | head -n 1)

java_major=$(
    java -version 2>&1 |
    awk -F '"' '/version/ {print $2}' |
    awk -F. '{if ($1 == 1) print $2; else print $1}'
)

if [[ -z "$java_major" || ! "$java_major" =~ ^[0-9]+$ || "$java_major" -lt 17 ]]; then
    die "Webin-CLI 9.x requires Java 17 or newer.
Current version: $JAVA_VERSION_LINE"
fi

DEFAULT_WEBIN_USER="${WEBIN_USER:-}"

echo
if [[ -n "$DEFAULT_WEBIN_USER" ]]; then
    read -r -p "Webin username [${DEFAULT_WEBIN_USER}]: " WEBIN_USER_INPUT
    WEBIN_USER="${WEBIN_USER_INPUT:-$DEFAULT_WEBIN_USER}"
else
    while [[ -z "${WEBIN_USER:-}" ]]; do
        read -r -p "Webin username: " WEBIN_USER
    done
fi

if [[ -z "${WEBIN_PASSWORD:-}" ]]; then
    echo
    read -r -s -p "Webin password for ${WEBIN_USER}: " WEBIN_PASSWORD
    echo
fi

[[ -n "$WEBIN_PASSWORD" ]] ||
    die "Webin password cannot be empty."

shopt -s nullglob
manifests=("$MANIFEST_DIR"/manifest_*)

if (( ${#manifests[@]} == 0 )); then
    die "No manifest files found matching ${MANIFEST_DIR}/manifest_*"
fi

first_manifest=${manifests[0]}
STUDY=$(
    awk -F':' '
        toupper($1) == "STUDY" {
            value=$2
            sub(/^[ \t]+/, "", value)
            sub(/[ \t\r]+$/, "", value)
            print value
            exit
        }
    ' "$first_manifest"
)

echo
echo "============================================================"
echo "You are about to SUBMIT reads to ENA."
echo "This action is not a validation-only dry run."
echo
echo "Study: ${STUDY:-UNKNOWN}"
echo "Manifest directory: $MANIFEST_DIR"
echo "Input FASTQ directory: $INPUT_DIR"
echo "Number of manifests: ${#manifests[@]}"
echo "Webin user: $WEBIN_USER"
echo "Java: $JAVA_VERSION_LINE"
echo "============================================================"
echo

read -r -p "Proceed with ENA submission? Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || {
    echo "Submission cancelled."
    exit 0
}

mkdir -p "$BASE_OUTPUT_DIR"
touch "$LOG_FILE" ||
    die "Cannot write log file: $LOG_FILE"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

log() {
    printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

log "============================================================"
log "ENA Webin-CLI batch submission started: $(timestamp)"
log "Mode: SUBMIT"
log "Java: $JAVA_VERSION_LINE"
log "Webin-CLI JAR: $WEBIN_JAR"
log "Webin user: $WEBIN_USER"
log "Study: ${STUDY:-UNKNOWN}"
log "Manifest directory: $MANIFEST_DIR"
log "Input FASTQ directory: $INPUT_DIR"
log "Base output directory: $BASE_OUTPUT_DIR"
log "Log file: $LOG_FILE"
log "============================================================"

total=${#manifests[@]}
succeeded=0
failed=0
skipped=0

SUMMARY_FILE="${BASE_OUTPUT_DIR}/webin_cli_submission_summary.tsv"
printf 'library_name\tmanifest\tstatus\texit_code\toutput_directory\n' > "$SUMMARY_FILE"

for manifest in "${manifests[@]}"; do
    library_name=$(
        awk -F':' '
            toupper($1) == "LIBRARY_NAME" {
                value=$2
                sub(/^[ \t]+/, "", value)
                sub(/[ \t\r]+$/, "", value)
                print value
                exit
            }
        ' "$manifest"
    )

    if [[ -z "$library_name" ]]; then
        log ""
        log "ERROR: Could not find LIBRARY_NAME in $manifest; skipping."
        printf '\t%s\tSKIPPED\t\t\n' "$manifest" >> "$SUMMARY_FILE"
        skipped=$((skipped + 1))
        continue
    fi

    safe_library_name=$(
        printf '%s' "$library_name" |
            sed 's/[^A-Za-z0-9._-]/_/g'
    )

    outdir="${BASE_OUTPUT_DIR}/outdir_${safe_library_name}"

    # Start from a clean, dedicated Webin output directory.
    rm -rf -- "$outdir"
    mkdir -p "$outdir"

    current=$((succeeded + failed + skipped + 1))

    log ""
    log "------------------------------------------------------------"
    log "Submitting [$current/$total]: $library_name"
    log "Manifest: $manifest"
    log "Output directory: $outdir"
    log "Started: $(timestamp)"
    log "------------------------------------------------------------"

    if java -jar "$WEBIN_JAR" \
        -context reads \
        -userName "$WEBIN_USER" \
        -password "$WEBIN_PASSWORD" \
        -manifest "$manifest" \
        -inputDir "$INPUT_DIR" \
        -outputDir "$outdir" \
        -submit \
        >> "$LOG_FILE" 2>&1
    then
        log "SUBMISSION SUCCEEDED: $library_name at $(timestamp)"
        printf '%s\t%s\tSUCCEEDED\t0\t%s\n' \
            "$library_name" "$manifest" "$outdir" >> "$SUMMARY_FILE"
        succeeded=$((succeeded + 1))
    else
        exit_code=$?
        log "SUBMISSION FAILED: $library_name returned exit code $exit_code at $(timestamp)"
        log "Continuing with the next manifest..."
        printf '%s\t%s\tFAILED\t%s\t%s\n' \
            "$library_name" "$manifest" "$exit_code" "$outdir" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
    fi
done

log ""
log "============================================================"
log "ENA Webin-CLI batch submission finished: $(timestamp)"
log "Total manifests: $total"
log "Succeeded: $succeeded"
log "Failed: $failed"
log "Skipped: $skipped"
log "Summary TSV: $SUMMARY_FILE"
log "Combined log: $LOG_FILE"
log "============================================================"

if (( failed > 0 || skipped > 0 )); then
    exit 1
fi

exit 0
