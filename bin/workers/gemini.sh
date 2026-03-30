#!/usr/bin/env bash
set -euo pipefail

# gemini.sh -- Worker stub for Gemini CLI
#
# Standard worker interface (same as codex.sh):
#   bin/workers/gemini.sh WORKING_DIR PROMPT_FILE OUTPUT_DIR LOG_FILE TIMEOUT [MODEL] [EXTRA_DIRS...]
#
# STATUS: Not yet implemented.
# To implement, install Gemini CLI and adapt this script following the
# same pattern as codex.sh. The interface contract is:
#   - Read prompt from PROMPT_FILE
#   - Write final result to OUTPUT_DIR/result.md
#   - Write errors to OUTPUT_DIR/stderr.log
#   - Write event log to LOG_FILE (if supported)
#   - Print token usage JSON to stdout
#   - Exit with the CLI's exit code

echo "ERROR: Gemini worker is not yet implemented." >&2
echo "" >&2
echo "To set up Gemini CLI:" >&2
echo "  1. Install: npm install -g @google/gemini-cli" >&2
echo "  2. Authenticate: gemini auth login" >&2
echo "  3. Implement this script following the codex.sh pattern" >&2
echo "" >&2
echo "See bin/workers/codex.sh for the reference implementation." >&2

exit 1
