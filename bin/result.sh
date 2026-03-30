#!/usr/bin/env bash
set -euo pipefail

# result.sh -- Read and display the result of a delegated codex task
#
# Usage: bin/result.sh [OPTIONS] TASK_ID
#
# Options:
#   --json    Output meta.json combined with result text as JSON
#   --full    Also print the JSONL event log
#   --meta    Print only meta.json
#   --task    Print the original task description

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="default"

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) MODE="json"; shift ;;
        --full) MODE="full"; shift ;;
        --meta) MODE="meta"; shift ;;
        --task) MODE="task"; shift ;;
        -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "ERROR: No task ID provided." >&2
    echo "Usage: bin/result.sh [--json|--full|--meta|--task] TASK_ID" >&2
    exit 1
fi

TASK_ID="$1"
ARTIFACT_DIR="${PROJECT_ROOT}/artifacts/${TASK_ID}"
LOG_FILE="${PROJECT_ROOT}/logs/${TASK_ID}.jsonl"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
    echo "ERROR: Task not found: ${TASK_ID}" >&2
    exit 1
fi

STATUS="pending"
[[ -f "${ARTIFACT_DIR}/status" ]] && STATUS="$(cat "${ARTIFACT_DIR}/status")"

case "$MODE" in
    task)
        if [[ -f "${ARTIFACT_DIR}/task.md" ]]; then
            cat "${ARTIFACT_DIR}/task.md"
        else
            echo "ERROR: No task.md found." >&2
            exit 1
        fi
        ;;

    meta)
        if [[ -f "${ARTIFACT_DIR}/meta.json" ]]; then
            cat "${ARTIFACT_DIR}/meta.json"
        else
            echo "ERROR: No meta.json found (task may still be running)." >&2
            exit 1
        fi
        ;;

    json)
        # Combine meta + result into a single JSON object
        META="{}"
        [[ -f "${ARTIFACT_DIR}/meta.json" ]] && META="$(cat "${ARTIFACT_DIR}/meta.json")"
        RESULT=""
        [[ -f "${ARTIFACT_DIR}/result.md" ]] && RESULT="$(cat "${ARTIFACT_DIR}/result.md")"
        STDERR=""
        [[ -f "${ARTIFACT_DIR}/stderr.log" ]] && STDERR="$(cat "${ARTIFACT_DIR}/stderr.log")"

        # Use python for safe JSON construction (handles escaping)
        python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
meta['status'] = sys.argv[2]
meta['result'] = sys.argv[3]
if sys.argv[4]:
    meta['stderr'] = sys.argv[4]
print(json.dumps(meta, indent=2))
" "$META" "$STATUS" "$RESULT" "$STDERR"
        ;;

    full)
        # Print result then event log
        echo "=== STATUS: ${STATUS} ==="
        echo ""
        if [[ -f "${ARTIFACT_DIR}/result.md" ]]; then
            echo "=== RESULT ==="
            cat "${ARTIFACT_DIR}/result.md"
            echo ""
        fi
        if [[ -f "${ARTIFACT_DIR}/meta.json" ]]; then
            echo "=== METADATA ==="
            cat "${ARTIFACT_DIR}/meta.json"
            echo ""
        fi
        if [[ -f "$LOG_FILE" ]]; then
            echo "=== EVENT LOG ==="
            cat "$LOG_FILE"
            echo ""
        fi
        if [[ -s "${ARTIFACT_DIR}/stderr.log" ]]; then
            echo "=== STDERR ==="
            cat "${ARTIFACT_DIR}/stderr.log"
        fi
        ;;

    default)
        echo "=== Task: ${TASK_ID} | Status: ${STATUS} ==="
        echo ""

        if [[ "$STATUS" == "running" ]]; then
            echo "Task is still running. Use bin/poll.sh to check status."
            exit 0
        fi

        if [[ "$STATUS" == "completed" ]] && [[ -f "${ARTIFACT_DIR}/result.md" ]]; then
            cat "${ARTIFACT_DIR}/result.md"
        elif [[ "$STATUS" == "failed" ]]; then
            echo "Task failed."
            [[ -f "${ARTIFACT_DIR}/exit_code" ]] && echo "Exit code: $(cat "${ARTIFACT_DIR}/exit_code")"
            echo ""
            if [[ -f "${ARTIFACT_DIR}/result.md" ]]; then
                echo "--- Partial result ---"
                cat "${ARTIFACT_DIR}/result.md"
                echo ""
            fi
            if [[ -s "${ARTIFACT_DIR}/stderr.log" ]]; then
                echo "--- Stderr ---"
                tail -30 "${ARTIFACT_DIR}/stderr.log"
            fi
        else
            echo "No result available yet."
        fi
        ;;
esac
