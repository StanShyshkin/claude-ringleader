#!/usr/bin/env bash
set -euo pipefail

# codex-review.sh -- Worker implementation for Codex CLI code review
#
# Standard review worker interface:
#   bin/workers/codex-review.sh WORKING_DIR OUTPUT_DIR REVIEW_ARGS...
#
# Inputs:
#   WORKING_DIR   Directory to review in
#   OUTPUT_DIR    Directory to write result.md
#   REVIEW_ARGS   Arguments passed to codex review (--uncommitted, --base, --commit, etc.)
#
# Outputs:
#   OUTPUT_DIR/result.md   -- Review output (stdout+stderr merged)
#   Exits with codex review's exit code

WORKING_DIR="$1"
OUTPUT_DIR="$2"
shift 2

REVIEW_ARGS=("$@")

EXIT_CODE=0
(
    cd "$WORKING_DIR"
    codex review "${REVIEW_ARGS[@]}" 2>&1
) > "${OUTPUT_DIR}/result.md" || EXIT_CODE=$?

exit "$EXIT_CODE"
