#!/usr/bin/env bash
set -euo pipefail

# gemini.sh -- Worker implementation for Gemini CLI
#
# Standard worker interface:
#   bin/workers/gemini.sh WORKING_DIR PROMPT_FILE OUTPUT_DIR LOG_FILE TIMEOUT [MODEL] [EXTRA_DIRS...]
#
# Inputs:
#   WORKING_DIR   Directory gemini works in
#   PROMPT_FILE   File containing the full prompt
#   OUTPUT_DIR    Directory to write result.md and stderr.log
#   LOG_FILE      Path for JSON output log
#   TIMEOUT       Timeout in seconds
#   MODEL         (optional) Model override (e.g. gemini-2.5-pro, gemini-2.5-flash)
#   EXTRA_DIRS    (optional) Additional context directories
#
# Outputs:
#   OUTPUT_DIR/result.md   -- Final agent response
#   OUTPUT_DIR/stderr.log  -- Stderr from gemini
#   LOG_FILE               -- Full JSON output (includes response + stats)
#   Exits with gemini's exit code
#
# Token usage:
#   Printed to stdout as JSON (extracted from gemini JSON output)

WORKING_DIR="$1"
PROMPT_FILE="$2"
OUTPUT_DIR="$3"
LOG_FILE="$4"
TIMEOUT="$5"
MODEL="${6:-}"
shift 6 || shift $#

# Remaining args are extra context directories
EXTRA_DIRS=("$@")

# Build gemini command
GEMINI_CMD=(
    gemini
    --output-format json
    --approval-mode yolo
)

if [[ -n "$MODEL" ]]; then
    GEMINI_CMD+=(-m "$MODEL")
fi

for dir in "${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}"; do
    GEMINI_CMD+=(--include-directories "$dir")
done

# Run gemini from the working directory
# Gemini uses cwd as its workspace (no -C flag like codex)
# -p flag triggers headless mode; prompt content piped via stdin
EXIT_CODE=0
timeout "${TIMEOUT}s" bash -c "
    cd \"$WORKING_DIR\" && \
    cat \"$PROMPT_FILE\" | $(printf '%q ' "${GEMINI_CMD[@]}") -p ' '
" > "$LOG_FILE" 2> "${OUTPUT_DIR}/stderr.log" || EXIT_CODE=$?

# Extract response and token usage from JSON output
if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
    # Extract response text -> result.md
    python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(data.get('response', ''))
except (json.JSONDecodeError, IOError):
    print('')
" "$LOG_FILE" > "${OUTPUT_DIR}/result.md" 2>/dev/null

    # Extract token usage -> stdout
    python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    stats = data.get('stats', {})
    models = stats.get('models', {})
    usage = {}
    for model_name, model_stats in models.items():
        tokens = model_stats.get('tokens', {})
        usage['input_tokens'] = usage.get('input_tokens', 0) + tokens.get('input', 0)
        usage['output_tokens'] = usage.get('output_tokens', 0) + tokens.get('candidates', 0)
        usage['cached_input_tokens'] = usage.get('cached_input_tokens', 0) + tokens.get('cached', 0)
        usage['total_tokens'] = usage.get('total_tokens', 0) + tokens.get('total', 0)
    print(json.dumps(usage))
except (json.JSONDecodeError, IOError, KeyError):
    print('{}')
" "$LOG_FILE" 2>/dev/null || echo "{}"
else
    # No output -- write empty result
    echo "" > "${OUTPUT_DIR}/result.md"
    echo "{}"
fi

exit "$EXIT_CODE"
