#!/usr/bin/env bash
set -euo pipefail

# worker-status.sh -- Check rate limit status for all workers
#
# Usage: bin/worker-status.sh [--clear]
#
# Shows which workers are rate-limited and when the lockout expires.
# Use --clear to remove all lockout files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="${ORCHESTRATOR_DATA_DIR:-${PROJECT_ROOT}}"

if [[ "${1:-}" == "--clear" ]]; then
    rm -f "${DATA_DIR}"/.worker-lockout-*
    echo "All worker lockouts cleared."
    exit 0
fi

NOW="$(date -u +%s)"
FOUND=false

for lockfile in "${DATA_DIR}"/.worker-lockout-*; do
    [[ -f "$lockfile" ]] || continue
    FOUND=true
    WORKER_NAME="$(basename "$lockfile" | sed 's/.worker-lockout-//')"
    LOCKOUT_UNTIL="$(cat "$lockfile")"

    if [[ "$NOW" -lt "$LOCKOUT_UNTIL" ]]; then
        REMAINING=$(( LOCKOUT_UNTIL - NOW ))
        echo "LOCKED: ${WORKER_NAME} -- rate-limited for ${REMAINING}s more (until $(date -u -d @"$LOCKOUT_UNTIL" +%H:%M:%S))"
    else
        echo "EXPIRED: ${WORKER_NAME} -- lockout expired, will be cleared on next use"
        rm -f "$lockfile"
    fi
done

if [[ "$FOUND" == false ]]; then
    echo "All workers available. No rate limits active."
fi
