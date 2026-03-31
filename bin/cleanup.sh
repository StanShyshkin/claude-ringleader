#!/usr/bin/env bash
set -euo pipefail

# cleanup.sh -- Remove old task artifacts and logs
#
# Usage: bin/cleanup.sh [OPTIONS]
#
# Options:
#   --days N     Remove artifacts older than N days (default: 7)
#   --all        Remove all artifacts
#   --dry-run    Show what would be deleted without deleting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="${ORCHESTRATOR_DATA_DIR:-${PROJECT_ROOT}}"
ARTIFACTS_DIR="${DATA_DIR}/artifacts"
LOGS_DIR="${DATA_DIR}/logs"

DAYS=7
ALL=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)    DAYS="$2"; shift 2 ;;
        --all)     ALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -*)        echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)         break ;;
    esac
done

REMOVED=0

for d in "$ARTIFACTS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    TASK_ID="$(basename "$d")"
    [[ "$TASK_ID" == ".gitkeep" ]] && continue

    SHOULD_REMOVE=false

    if [[ "$ALL" == true ]]; then
        SHOULD_REMOVE=true
    else
        # Extract date from task ID (YYYYMMDD-HHMMSS-slug)
        TASK_DATE="${TASK_ID:0:8}"
        if [[ "$TASK_DATE" =~ ^[0-9]{8}$ ]]; then
            CUTOFF="$(date -u -d "${DAYS} days ago" +%Y%m%d)"
            if [[ "$TASK_DATE" -lt "$CUTOFF" ]]; then
                SHOULD_REMOVE=true
            fi
        fi
    fi

    if [[ "$SHOULD_REMOVE" == true ]]; then
        LOG_FILE="${LOGS_DIR}/${TASK_ID}.jsonl"
        if [[ "$DRY_RUN" == true ]]; then
            echo "would remove: artifacts/${TASK_ID}/"
            [[ -f "$LOG_FILE" ]] && echo "would remove: logs/${TASK_ID}.jsonl"
        else
            rm -rf "$d"
            [[ -f "$LOG_FILE" ]] && rm -f "$LOG_FILE"
            echo "removed: ${TASK_ID}"
        fi
        REMOVED=$((REMOVED + 1))
    fi
done

if [[ "$DRY_RUN" == true ]]; then
    echo "${REMOVED} task(s) would be removed."
else
    echo "${REMOVED} task(s) removed."
fi
