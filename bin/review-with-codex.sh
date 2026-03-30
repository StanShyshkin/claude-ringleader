#!/usr/bin/env bash
set -euo pipefail

# review-with-codex.sh -- Delegate a code review to Codex CLI
#
# Usage:
#   bin/review-with-codex.sh [OPTIONS]
#
# Options:
#   --uncommitted          Review staged, unstaged, and untracked changes
#   --base BRANCH          Review changes against a base branch
#   --commit SHA           Review a specific commit
#   --title TITLE          Optional title for the review
#   -d DIR                 Working directory (default: current directory)
#   -s SLUG                Custom slug for task ID
#   -p PROMPT              Additional review instructions (appended to template)
#   -q                     Quiet mode

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
WORKING_DIR="$(pwd)"
SLUG=""
QUIET=false
REVIEW_ARGS=()
EXTRA_PROMPT=""
TITLE=""

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uncommitted) REVIEW_ARGS+=(--uncommitted); shift ;;
        --base)        REVIEW_ARGS+=(--base "$2"); shift 2 ;;
        --commit)      REVIEW_ARGS+=(--commit "$2"); shift 2 ;;
        --title)       TITLE="$2"; REVIEW_ARGS+=(--title "$2"); shift 2 ;;
        -d)            WORKING_DIR="$(cd "$2" && pwd)"; shift 2 ;;
        -s)            SLUG="$2"; shift 2 ;;
        -p)            EXTRA_PROMPT="$2"; shift 2 ;;
        -q)            QUIET=true; shift ;;
        --)            shift; break ;;
        -*)            echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)             break ;;
    esac
done

# Require at least one review scope flag
if [[ ${#REVIEW_ARGS[@]} -eq 0 ]]; then
    echo "ERROR: Specify at least one of: --uncommitted, --base BRANCH, --commit SHA" >&2
    echo "Usage: bin/review-with-codex.sh --uncommitted [-d DIR]" >&2
    exit 1
fi

# Generate task ID
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
if [[ -n "$SLUG" ]]; then
    TASK_ID="${TIMESTAMP}-${SLUG}"
else
    TASK_ID="${TIMESTAMP}-review"
fi

# Create artifact directory
ARTIFACT_DIR="${PROJECT_ROOT}/artifacts/${TASK_ID}"
mkdir -p "$ARTIFACT_DIR"

LOG_FILE="${PROJECT_ROOT}/logs/${TASK_ID}.jsonl"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the review prompt from template + extra instructions
TEMPLATE="${PROJECT_ROOT}/templates/review-prompt.md"
PROMPT=""
if [[ -f "$TEMPLATE" ]]; then
    PROMPT="$(cat "$TEMPLATE")"
fi
if [[ -n "$EXTRA_PROMPT" ]]; then
    PROMPT="${PROMPT}"$'\n\n'"${EXTRA_PROMPT}"
fi

# Write task.md
cat > "${ARTIFACT_DIR}/task.md" <<EOF
---
task_id: ${TASK_ID}
created_at: ${STARTED_AT}
delegated_by: claude
worker: codex
type: review
status: pending
working_dir: ${WORKING_DIR}
review_args: ${REVIEW_ARGS[*]}
---

## Code Review

Review scope: ${REVIEW_ARGS[*]}
${TITLE:+Title: ${TITLE}}
${EXTRA_PROMPT:+Additional instructions: ${EXTRA_PROMPT}}
EOF

# Save the prompt for debugging
echo "$PROMPT" > "${ARTIFACT_DIR}/prompt.md"

# Mark as running
echo "running" > "${ARTIFACT_DIR}/status.tmp"
mv "${ARTIFACT_DIR}/status.tmp" "${ARTIFACT_DIR}/status"

[[ "$QUIET" == false ]] && echo "Review ${TASK_ID} started (dir: ${WORKING_DIR}, scope: ${REVIEW_ARGS[*]})" >&2

# Run review via worker
REVIEW_WORKER="${SCRIPT_DIR}/workers/codex-review.sh"
EXIT_CODE=0
"$REVIEW_WORKER" "$WORKING_DIR" "$ARTIFACT_DIR" "${REVIEW_ARGS[@]}" || EXIT_CODE=$?

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
  "type": "review",
  "started_at": "${STARTED_AT}",
  "finished_at": "${FINISHED_AT}",
  "exit_code": ${EXIT_CODE},
  "working_dir": "${WORKING_DIR}",
  "review_args": "${REVIEW_ARGS[*]}"
}
EOF

if [[ "$EXIT_CODE" -eq 0 ]]; then
    [[ "$QUIET" == false ]] && echo "Review ${TASK_ID} completed." >&2
else
    [[ "$QUIET" == false ]] && echo "Review ${TASK_ID} failed (exit code: ${EXIT_CODE})." >&2
    if [[ -s "${ARTIFACT_DIR}/stderr.log" ]]; then
        [[ "$QUIET" == false ]] && echo "--- stderr ---" >&2
        [[ "$QUIET" == false ]] && tail -20 "${ARTIFACT_DIR}/stderr.log" >&2
    fi
fi

echo "$TASK_ID"
exit "$EXIT_CODE"
