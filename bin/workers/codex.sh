#!/usr/bin/env bash
set -euo pipefail

# codex.sh -- Worker implementation for Codex CLI
#
# Standard worker interface:
#   bin/workers/codex.sh WORKING_DIR PROMPT_FILE OUTPUT_DIR LOG_FILE TIMEOUT [MODEL] [EXTRA_DIRS...]
#
# Inputs:
#   WORKING_DIR   Directory codex works in
#   PROMPT_FILE   File containing the full prompt (read via stdin)
#   OUTPUT_DIR    Directory to write result.md and stderr.log
#   LOG_FILE      Path for JSONL event log
#   TIMEOUT       Timeout in seconds
#   MODEL         (optional) Model override
#   EXTRA_DIRS    (optional) Additional writable directories
#
# Outputs:
#   OUTPUT_DIR/result.md   -- Final agent message
#   OUTPUT_DIR/stderr.log  -- Stderr from codex
#   LOG_FILE               -- JSONL event stream
#   Exits with codex's exit code
#
# Token usage:
#   Printed to stdout as JSON on success (extracted from JSONL log)

WORKING_DIR="$1"
PROMPT_FILE="$2"
OUTPUT_DIR="$3"
LOG_FILE="$4"
TIMEOUT="$5"
MODEL="${6:-}"
shift 6 || shift $#

# Remaining args are extra writable directories
EXTRA_DIRS=("$@")

# Build codex command
CODEX_CMD=(
    codex exec -
    --full-auto
    --ephemeral
    -C "$WORKING_DIR"
    --skip-git-repo-check
    -o "${OUTPUT_DIR}/result.md"
    --json
)

if [[ -n "$MODEL" ]]; then
    CODEX_CMD+=(-c "model=${MODEL}")
fi

for dir in "${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}"; do
    CODEX_CMD+=(--add-dir "$dir")
done

# Structured output schema (opt-in via environment variable)
if [[ -n "${CODEX_OUTPUT_SCHEMA:-}" ]]; then
    CODEX_CMD+=(--output-schema "$CODEX_OUTPUT_SCHEMA")
fi

# Run codex
EXIT_CODE=0
timeout "${TIMEOUT}s" "${CODEX_CMD[@]}" \
    < "$PROMPT_FILE" \
    > "$LOG_FILE" \
    2> "${OUTPUT_DIR}/stderr.log" \
    || EXIT_CODE=$?

# Extract and print token usage from JSONL log
if [[ -f "$LOG_FILE" ]]; then
    python3 -c "
import json, sys
usage = {}
for line in open(sys.argv[1]):
    try:
        evt = json.loads(line)
        if evt.get('type') == 'turn.completed' and 'usage' in evt:
            usage = evt['usage']
    except (json.JSONDecodeError, KeyError):
        pass
print(json.dumps(usage))
" "$LOG_FILE" 2>/dev/null || echo "{}"
else
    echo "{}"
fi

exit "$EXIT_CODE"
