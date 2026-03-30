#!/usr/bin/env bash
set -euo pipefail

# list-tasks.sh -- List all delegated tasks and their statuses
#
# Usage: bin/list-tasks.sh [OPTIONS]
#
# Options:
#   --running      Show only running tasks
#   --completed    Show only completed tasks
#   --failed       Show only failed tasks
#   --json         Output as JSON array

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"

FILTER=""
JSON_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --running)   FILTER="running"; shift ;;
        --completed) FILTER="completed"; shift ;;
        --failed)    FILTER="failed"; shift ;;
        --json)      JSON_MODE=true; shift ;;
        -*)          echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)           break ;;
    esac
done

# Collect task directories (sorted by name = chronological)
TASK_DIRS=()
for d in "$ARTIFACTS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" == ".gitkeep" ]] && continue
    TASK_DIRS+=("$d")
done

if [[ ${#TASK_DIRS[@]} -eq 0 ]]; then
    echo "No tasks found."
    exit 0
fi

# Print header (non-JSON)
if [[ "$JSON_MODE" == false ]]; then
    printf "%-45s %-12s %-10s %s\n" "TASK_ID" "STATUS" "DURATION" "WORKING_DIR"
    printf "%-45s %-12s %-10s %s\n" "-------" "------" "--------" "-----------"
fi

JSON_ENTRIES=()

for d in "${TASK_DIRS[@]}"; do
    TASK_ID="$(basename "$d")"
    STATUS="unknown"
    DURATION="-"
    DIR="-"

    [[ -f "${d}status" ]] && STATUS="$(cat "${d}status")"

    # Apply filter
    if [[ -n "$FILTER" ]] && [[ "$STATUS" != "$FILTER" ]]; then
        continue
    fi

    # Extract duration and working_dir from meta.json if available
    if [[ -f "${d}meta.json" ]]; then
        DIR="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('working_dir','-'))" "${d}meta.json" 2>/dev/null || echo "-")"

        DURATION="$(python3 -c "
import json,sys
from datetime import datetime
d=json.load(open(sys.argv[1]))
s=d.get('started_at','')
f=d.get('finished_at','')
if s and f:
    fmt='%Y-%m-%dT%H:%M:%SZ'
    delta=datetime.strptime(f,fmt)-datetime.strptime(s,fmt)
    print(f'{int(delta.total_seconds())}s')
else:
    print('-')
" "${d}meta.json" 2>/dev/null || echo "-")"
    fi

    if [[ "$JSON_MODE" == true ]]; then
        JSON_ENTRIES+=("{\"task_id\":\"${TASK_ID}\",\"status\":\"${STATUS}\",\"duration\":\"${DURATION}\",\"working_dir\":\"${DIR}\"}")
    else
        printf "%-45s %-12s %-10s %s\n" "$TASK_ID" "$STATUS" "$DURATION" "$DIR"
    fi
done

if [[ "$JSON_MODE" == true ]]; then
    # Join entries
    echo "["
    for i in "${!JSON_ENTRIES[@]}"; do
        if [[ $i -lt $((${#JSON_ENTRIES[@]} - 1)) ]]; then
            echo "  ${JSON_ENTRIES[$i]},"
        else
            echo "  ${JSON_ENTRIES[$i]}"
        fi
    done
    echo "]"
fi
