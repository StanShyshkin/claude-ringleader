#!/usr/bin/env bash
set -euo pipefail

# delegate.sh -- Delegate a bounded task to Codex CLI
#
# Usage:
#   bin/delegate.sh [OPTIONS] TASK_DESCRIPTION
#   echo "task text" | bin/delegate.sh [OPTIONS] -
#
# Options:
#   -d DIR       Working directory for codex (default: current directory)
#   -t SECONDS   Timeout in seconds (default: 300)
#   -s SLUG      Custom slug for task ID (default: auto-generated)
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

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) WORKING_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        -t) TIMEOUT="$2"; shift 2 ;;
        -s) SLUG="$2"; shift 2 ;;
        -q) QUIET=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

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

# Write task.md
cat > "${ARTIFACT_DIR}/task.md" <<EOF
---
task_id: ${TASK_ID}
created_at: ${STARTED_AT}
delegated_by: claude
worker: codex
status: pending
working_dir: ${WORKING_DIR}
timeout_seconds: ${TIMEOUT}
---

${TASK_DESC}
EOF

# Compose prompt: template preamble + task content
TEMPLATE="${PROJECT_ROOT}/templates/task-prompt.md"
if [[ -f "$TEMPLATE" ]]; then
    cat "$TEMPLATE" > "${ARTIFACT_DIR}/prompt.md"
    echo "" >> "${ARTIFACT_DIR}/prompt.md"
    echo "$TASK_DESC" >> "${ARTIFACT_DIR}/prompt.md"
else
    # Fallback if template missing
    echo "$TASK_DESC" > "${ARTIFACT_DIR}/prompt.md"
fi

# Mark as running
echo "running" > "${ARTIFACT_DIR}/status.tmp"
mv "${ARTIFACT_DIR}/status.tmp" "${ARTIFACT_DIR}/status"

[[ "$QUIET" == false ]] && echo "Task ${TASK_ID} started (timeout: ${TIMEOUT}s, dir: ${WORKING_DIR})" >&2

# Build codex command
CODEX_CMD=(
    codex exec -
    --full-auto
    --ephemeral
    -C "$WORKING_DIR"
    --skip-git-repo-check
    -o "${ARTIFACT_DIR}/result.md"
    --json
)

# Store PID info and the full command for debugging
CODEX_CMD_STR="${CODEX_CMD[*]}"

# Run codex, capturing exit code
EXIT_CODE=0
timeout "${TIMEOUT}s" "${CODEX_CMD[@]}" \
    < "${ARTIFACT_DIR}/prompt.md" \
    > "$LOG_FILE" \
    2> "${ARTIFACT_DIR}/stderr.log" \
    &
CODEX_PID=$!

# Write PID file
echo "$CODEX_PID" > "${ARTIFACT_DIR}/pid"

# Wait for codex to finish
wait "$CODEX_PID" || EXIT_CODE=$?

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

# Write meta.json
cat > "${ARTIFACT_DIR}/meta.json" <<EOF
{
  "task_id": "${TASK_ID}",
  "pid": ${CODEX_PID},
  "started_at": "${STARTED_AT}",
  "finished_at": "${FINISHED_AT}",
  "exit_code": ${EXIT_CODE},
  "working_dir": "${WORKING_DIR}",
  "command": "${CODEX_CMD_STR}"
}
EOF

# Final output
if [[ "$EXIT_CODE" -eq 0 ]]; then
    [[ "$QUIET" == false ]] && echo "Task ${TASK_ID} completed successfully." >&2
else
    [[ "$QUIET" == false ]] && echo "Task ${TASK_ID} failed (exit code: ${EXIT_CODE})." >&2
    # Print stderr for immediate debugging
    if [[ -s "${ARTIFACT_DIR}/stderr.log" ]]; then
        [[ "$QUIET" == false ]] && echo "--- stderr ---" >&2
        [[ "$QUIET" == false ]] && tail -20 "${ARTIFACT_DIR}/stderr.log" >&2
    fi
fi

# Always print the task ID as last line of stdout (for capture by caller)
echo "$TASK_ID"

exit "$EXIT_CODE"
