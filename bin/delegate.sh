#!/usr/bin/env bash
set -euo pipefail

# delegate.sh -- Delegate a bounded task to a worker CLI
#
# Usage:
#   bin/delegate.sh [OPTIONS] TASK_DESCRIPTION
#   echo "task text" | bin/delegate.sh [OPTIONS] -
#
# Options:
#   -d DIR       Working directory for the worker (default: current directory)
#   -t SECONDS   Timeout in seconds (default: 300)
#   -s SLUG      Custom slug for task ID (default: auto-generated)
#   -m MODEL     Override model (e.g. gpt-4o, o3)
#   -w WORKER    Worker to use: codex (default), gemini
#   -r N         Retry up to N times on failure (default: 0)
#   -a DIR       Additional writable directory (can be repeated)
#   -c FILE      Context file to include in prompt (can be repeated)
#   -q           Quiet mode (suppress progress output)
#
# Outputs:
#   Prints the TASK_ID to stdout on the last line.
#   All artifacts written to artifacts/{TASK_ID}/
#   Event log written to logs/{TASK_ID}.jsonl

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
WORKING_DIR="$(pwd)"
TIMEOUT=300
SLUG=""
QUIET=false
MODEL=""
WORKER="codex"
MAX_RETRIES=0
EXTRA_DIRS=()
CONTEXT_FILES=()

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) WORKING_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        -t) TIMEOUT="$2"; shift 2 ;;
        -s) SLUG="$2"; shift 2 ;;
        -m) MODEL="$2"; shift 2 ;;
        -w) WORKER="$2"; shift 2 ;;
        -r) MAX_RETRIES="$2"; shift 2 ;;
        -a) EXTRA_DIRS+=("$(cd "$2" && pwd)"); shift 2 ;;
        -c) CONTEXT_FILES+=("$2"); shift 2 ;;
        -q) QUIET=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

# Validate worker exists
WORKER_SCRIPT="${SCRIPT_DIR}/workers/${WORKER}.sh"
if [[ ! -x "$WORKER_SCRIPT" ]]; then
    echo "ERROR: Worker not found or not executable: ${WORKER_SCRIPT}" >&2
    echo "Available workers:" >&2
    for w in "${SCRIPT_DIR}"/workers/*.sh; do
        [[ -x "$w" ]] && echo "  $(basename "$w" .sh)" >&2
    done
    exit 1
fi

# Read task description from args or stdin
if [[ $# -eq 0 ]]; then
    echo "ERROR: No task description provided." >&2
    echo "Usage: bin/delegate.sh [OPTIONS] TASK_DESCRIPTION" >&2
    exit 1
fi

if [[ "$1" == "-" ]]; then
    TASK_DESC="$(cat)"
else
    TASK_DESC="$*"
fi

if [[ -z "$TASK_DESC" ]]; then
    echo "ERROR: Task description is empty." >&2
    exit 1
fi

# Generate task ID
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
if [[ -n "$SLUG" ]]; then
    TASK_ID="${TIMESTAMP}-${SLUG}"
else
    # Auto-generate slug from first 5 words of description
    AUTO_SLUG="$(echo "$TASK_DESC" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | cut -d'-' -f1-5)"
    TASK_ID="${TIMESTAMP}-${AUTO_SLUG}"
fi

# Create artifact directory
ARTIFACT_DIR="${PROJECT_ROOT}/artifacts/${TASK_ID}"
mkdir -p "$ARTIFACT_DIR"

LOG_FILE="${PROJECT_ROOT}/logs/${TASK_ID}.jsonl"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# EXIT trap: ensure status is always written on unexpected termination
cleanup() {
    local rc=$?
    if [[ -d "$ARTIFACT_DIR" ]] && [[ -f "${ARTIFACT_DIR}/status" ]]; then
        local current_status
        current_status="$(cat "${ARTIFACT_DIR}/status")"
        if [[ "$current_status" == "running" ]]; then
            echo "failed" > "${ARTIFACT_DIR}/status.tmp"
            mv "${ARTIFACT_DIR}/status.tmp" "${ARTIFACT_DIR}/status"
            echo "$rc" > "${ARTIFACT_DIR}/exit_code"
        fi
    fi
}
trap cleanup EXIT

# Write task.md
cat > "${ARTIFACT_DIR}/task.md" <<EOF
---
task_id: ${TASK_ID}
created_at: ${STARTED_AT}
delegated_by: claude
worker: ${WORKER}
status: pending
working_dir: ${WORKING_DIR}
timeout_seconds: ${TIMEOUT}
${MODEL:+model: ${MODEL}}
---

${TASK_DESC}
EOF

# Compose prompt: template preamble + task content + context files
TEMPLATE="${PROJECT_ROOT}/templates/task-prompt.md"
if [[ -f "$TEMPLATE" ]]; then
    cat "$TEMPLATE" > "${ARTIFACT_DIR}/prompt.md"
    echo "" >> "${ARTIFACT_DIR}/prompt.md"
    echo "$TASK_DESC" >> "${ARTIFACT_DIR}/prompt.md"
else
    # Fallback if template missing
    echo "$TASK_DESC" > "${ARTIFACT_DIR}/prompt.md"
fi

# Append context files if provided
for ctx_file in "${CONTEXT_FILES[@]+"${CONTEXT_FILES[@]}"}"; do
    if [[ -f "$ctx_file" ]]; then
        echo "" >> "${ARTIFACT_DIR}/prompt.md"
        echo "--- CONTEXT FROM: $(basename "$ctx_file") ---" >> "${ARTIFACT_DIR}/prompt.md"
        cat "$ctx_file" >> "${ARTIFACT_DIR}/prompt.md"
    else
        echo "WARNING: Context file not found: ${ctx_file}" >&2
    fi
done

# Mark as running
echo "running" > "${ARTIFACT_DIR}/status.tmp"
mv "${ARTIFACT_DIR}/status.tmp" "${ARTIFACT_DIR}/status"

[[ "$QUIET" == false ]] && echo "Task ${TASK_ID} started (worker: ${WORKER}, timeout: ${TIMEOUT}s, dir: ${WORKING_DIR}${MODEL:+, model: ${MODEL}})" >&2

# Invoke the worker
# Worker interface: WORKING_DIR PROMPT_FILE OUTPUT_DIR LOG_FILE TIMEOUT [MODEL] [EXTRA_DIRS...]
WORKER_ARGS=("$WORKING_DIR" "${ARTIFACT_DIR}/prompt.md" "$ARTIFACT_DIR" "$LOG_FILE" "$TIMEOUT")
[[ -n "$MODEL" ]] && WORKER_ARGS+=("$MODEL") || WORKER_ARGS+=("")
WORKER_ARGS+=("${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}")

# Retry loop
ATTEMPT=0
EXIT_CODE=0
TOKEN_USAGE=""
TOTAL_ATTEMPTS=1

while true; do
    ATTEMPT=$((ATTEMPT + 1))

    # On retry: archive previous attempt and augment prompt with error context
    if [[ "$ATTEMPT" -gt 1 ]]; then
        PREV_DIR="${ARTIFACT_DIR}/attempt-$((ATTEMPT - 1))"
        mkdir -p "$PREV_DIR"
        for f in result.md stderr.log exit_code; do
            [[ -f "${ARTIFACT_DIR}/$f" ]] && mv "${ARTIFACT_DIR}/$f" "${PREV_DIR}/"
        done

        # Augment prompt with error context
        {
            echo ""
            echo "--- RETRY (attempt ${ATTEMPT} of $((MAX_RETRIES + 1))) ---"
            echo "The previous attempt failed."
            if [[ -f "${PREV_DIR}/stderr.log" ]] && [[ -s "${PREV_DIR}/stderr.log" ]]; then
                echo ""
                echo "Stderr from previous attempt:"
                cat "${PREV_DIR}/stderr.log"
            fi
            if [[ -f "${PREV_DIR}/result.md" ]] && [[ -s "${PREV_DIR}/result.md" ]]; then
                echo ""
                echo "Partial result from previous attempt:"
                cat "${PREV_DIR}/result.md"
            fi
            echo ""
            echo "Please fix the issues and complete the original task."
        } >> "${ARTIFACT_DIR}/prompt.md"

        [[ "$QUIET" == false ]] && echo "Retrying (attempt ${ATTEMPT}/$((MAX_RETRIES + 1)))..." >&2
    fi

    EXIT_CODE=0
    ATTEMPT_USAGE="$("$WORKER_SCRIPT" "${WORKER_ARGS[@]}")" || EXIT_CODE=$?

    # Accumulate token usage across attempts
    if [[ -n "$ATTEMPT_USAGE" ]] && [[ "$ATTEMPT_USAGE" != "{}" ]]; then
        if [[ -z "$TOKEN_USAGE" ]] || [[ "$TOKEN_USAGE" == "{}" ]]; then
            TOKEN_USAGE="$ATTEMPT_USAGE"
        else
            # Sum token usage from all attempts
            TOKEN_USAGE="$(python3 -c "
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
merged = {}
for k in set(list(a.keys()) + list(b.keys())):
    merged[k] = a.get(k, 0) + b.get(k, 0)
print(json.dumps(merged))
" "$TOKEN_USAGE" "$ATTEMPT_USAGE" 2>/dev/null || echo "$ATTEMPT_USAGE")"
        fi
    fi

    TOTAL_ATTEMPTS="$ATTEMPT"

    if [[ "$EXIT_CODE" -eq 0 ]] || [[ "$ATTEMPT" -gt "$MAX_RETRIES" ]]; then
        break
    fi
done

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Write exit code
echo "$EXIT_CODE" > "${ARTIFACT_DIR}/exit_code"

# Update status atomically
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "completed" > "${ARTIFACT_DIR}/status.tmp"
else
    echo "failed" > "${ARTIFACT_DIR}/status.tmp"
fi
mv "${ARTIFACT_DIR}/status.tmp" "${ARTIFACT_DIR}/status"

# Write meta.json (TOKEN_USAGE comes from worker's stdout, accumulated across retries)
EMPTY_JSON="{}"
python3 -c "
import json, sys
meta = {
    'task_id': sys.argv[1],
    'worker': sys.argv[2],
    'started_at': sys.argv[3],
    'finished_at': sys.argv[4],
    'exit_code': int(sys.argv[5]),
    'working_dir': sys.argv[6],
    'total_attempts': int(sys.argv[9]),
}
try:
    usage = json.loads(sys.argv[7])
    if usage:
        meta['token_usage'] = usage
except (json.JSONDecodeError, ValueError):
    pass
if sys.argv[8]:
    meta['model'] = sys.argv[8]
print(json.dumps(meta, indent=2))
" "$TASK_ID" "$WORKER" "$STARTED_AT" "$FINISHED_AT" "$EXIT_CODE" \
  "$WORKING_DIR" "${TOKEN_USAGE:-$EMPTY_JSON}" "$MODEL" "$TOTAL_ATTEMPTS" \
  > "${ARTIFACT_DIR}/meta.json"

# Final output
if [[ "$EXIT_CODE" -eq 0 ]]; then
    [[ "$QUIET" == false ]] && echo "Task ${TASK_ID} completed successfully." >&2
else
    [[ "$QUIET" == false ]] && echo "Task ${TASK_ID} failed (exit code: ${EXIT_CODE})." >&2
    if [[ -s "${ARTIFACT_DIR}/stderr.log" ]]; then
        [[ "$QUIET" == false ]] && echo "--- stderr ---" >&2
        [[ "$QUIET" == false ]] && tail -20 "${ARTIFACT_DIR}/stderr.log" >&2
    fi
fi

# Always print the task ID as last line of stdout (for capture by caller)
echo "$TASK_ID"

exit "$EXIT_CODE"
