#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<'EOF'
Validate all ENA read manifests with Webin-CLI without submitting them.

Usage:
  ./validate_all_ena_manifests_fixed.sh

Optional KEY=VALUE overrides:
  ./validate_all_ena_manifests_fixed.sh \
    ROOT_DIR="/path/to/project/root" \
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

The script uses Webin-CLI -validate, not -submit.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 2
}

# Load the correct java module
module load Java/17.0.17

# Process KEY=VALUE arguments before assigning defaults.
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
BASE_OUTPUT_DIR="${BASE_OUTPUT_DIR:-${ROOT_DIR}/ena_submission/outputs/webin_validation}"
LOG_FILE="${LOG_FILE:-${BASE_OUTPUT_DIR}/webin_cli_validation_all.log}"

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

DEFAULT_WEBIN_USER="${WEBIN_USER:-Webin-69778}"

echo
read -r -p "Webin username [${DEFAULT_WEBIN_USER}]: " WEBIN_USER_INPUT
WEBIN_USER="${WEBIN_USER_INPUT:-$DEFAULT_WEBIN_USER}"

if [[ -z "${WEBIN_PASSWORD:-}" ]]; then
    echo
    read -r -s -p "Webin password for ${WEBIN_USER}: " WEBIN_PASSWORD
    echo
fi

[[ -n "$WEBIN_PASSWORD" ]] ||
    die "Webin password cannot be empty."

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
log "ENA Webin-CLI batch validation started: $(timestamp)"
log "Mode: VALIDATE ONLY — no submission will be made"
log "Java: $JAVA_VERSION_LINE"
log "Webin-CLI JAR: $WEBIN_JAR"
log "Webin user: $WEBIN_USER"
log "Manifest directory: $MANIFEST_DIR"
log "Input FASTQ directory: $INPUT_DIR"
log "Base output directory: $BASE_OUTPUT_DIR"
log "Log file: $LOG_FILE"
log "============================================================"

shopt -s nullglob
manifests=("$MANIFEST_DIR"/manifest_*)

if (( ${#manifests[@]} == 0 )); then
    log "ERROR: No manifest files found matching ${MANIFEST_DIR}/manifest_*"
    exit 1
fi

total=${#manifests[@]}
passed=0
failed=0
skipped=0

SUMMARY_FILE="${BASE_OUTPUT_DIR}/webin_cli_validation_summary.tsv"
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
    mkdir -p "$outdir"

    current=$((passed + failed + skipped + 1))

    log ""
    log "------------------------------------------------------------"
    log "Validating [$current/$total]: $library_name"
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
        -validate \
        >> "$LOG_FILE" 2>&1
    then
        log "VALIDATION PASSED: $library_name at $(timestamp)"
        printf '%s\t%s\tPASSED\t0\t%s\n' \
            "$library_name" "$manifest" "$outdir" >> "$SUMMARY_FILE"
        passed=$((passed + 1))
    else
        exit_code=$?
        log "VALIDATION FAILED: $library_name returned exit code $exit_code at $(timestamp)"
        log "Continuing with the next manifest..."
        printf '%s\t%s\tFAILED\t%s\t%s\n' \
            "$library_name" "$manifest" "$exit_code" "$outdir" >> "$SUMMARY_FILE"
        failed=$((failed + 1))
    fi
done

log ""
log "============================================================"
log "ENA Webin-CLI batch validation finished: $(timestamp)"
log "Total manifests: $total"
log "Passed: $passed"
log "Failed: $failed"
log "Skipped: $skipped"
log "Summary TSV: $SUMMARY_FILE"
log "Combined log: $LOG_FILE"
log "============================================================"

if (( failed > 0 || skipped > 0 )); then
    exit 1
fi

exit 0
