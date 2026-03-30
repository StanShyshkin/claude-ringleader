#!/usr/bin/env bash
set -euo pipefail

# poll.sh -- Check if a delegated codex task has finished
#
# Usage: bin/poll.sh TASK_ID
#
# Exit codes:
#   0 = completed
#   1 = failed
#   2 = still running
#   3 = task not found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -eq 0 ]]; then
    echo "ERROR: No task ID provided." >&2
    echo "Usage: bin/poll.sh TASK_ID" >&2
    exit 3
fi

TASK_ID="$1"
ARTIFACT_DIR="${PROJECT_ROOT}/artifacts/${TASK_ID}"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
    echo "ERROR: Task not found: ${TASK_ID}" >&2
    exit 3
fi

STATUS_FILE="${ARTIFACT_DIR}/status"
PID_FILE="${ARTIFACT_DIR}/pid"

if [[ ! -f "$STATUS_FILE" ]]; then
    echo "ERROR: No status file for task ${TASK_ID}" >&2
    exit 3
fi

STATUS="$(cat "$STATUS_FILE")"

case "$STATUS" in
    completed)
        echo "COMPLETED: Task ${TASK_ID} finished successfully."
        exit 0
        ;;
    failed)
        EXIT_CODE="unknown"
        [[ -f "${ARTIFACT_DIR}/exit_code" ]] && EXIT_CODE="$(cat "${ARTIFACT_DIR}/exit_code")"
        echo "FAILED: Task ${TASK_ID} (exit code: ${EXIT_CODE})."
        exit 1
        ;;
    running)
        # Verify the process is actually still alive
        if [[ -f "$PID_FILE" ]]; then
            PID="$(cat "$PID_FILE")"
            if kill -0 "$PID" 2>/dev/null; then
                echo "RUNNING: Task ${TASK_ID} (pid: ${PID})."
                exit 2
            else
                # Process died without updating status -- mark as failed
                echo "failed" > "${ARTIFACT_DIR}/status.tmp"
                mv "${ARTIFACT_DIR}/status.tmp" "${ARTIFACT_DIR}/status"
                echo "FAILED: Task ${TASK_ID} (process ${PID} died unexpectedly)."
                exit 1
            fi
        else
            echo "RUNNING: Task ${TASK_ID} (no pid file)."
            exit 2
        fi
        ;;
    *)
        echo "UNKNOWN: Task ${TASK_ID} has status '${STATUS}'." >&2
        exit 3
        ;;
esac
