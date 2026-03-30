#!/usr/bin/env bash
set -euo pipefail

# workflow.sh -- Run a multi-step plan, delegating each step to codex
#
# Usage: bin/workflow.sh [OPTIONS] PLAN_FILE
#
# Options:
#   -t SECONDS   Per-step timeout (default: 300)
#   -m MODEL     Override model for all steps
#   --dry-run    Parse and print the plan without executing
#   -q           Quiet mode
#
# Plan file format: see templates/plan-template.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TIMEOUT=300
MODEL=""
DRY_RUN=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) TIMEOUT="$2"; shift 2 ;;
        -m) MODEL="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -q) QUIET=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)  break ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "ERROR: No plan file provided." >&2
    echo "Usage: bin/workflow.sh [OPTIONS] PLAN_FILE" >&2
    exit 1
fi

PLAN_FILE="$1"
if [[ ! -f "$PLAN_FILE" ]]; then
    echo "ERROR: Plan file not found: ${PLAN_FILE}" >&2
    exit 1
fi

# --- Parse the plan file ---

# Global working_dir (can be overridden per step)
GLOBAL_WORKING_DIR=""

# Arrays to hold parsed steps (parallel arrays, indexed by step number)
STEP_NAMES=()
STEP_TASKS=()
STEP_DEPENDS=()
STEP_TYPES=()
STEP_DIRS=()

current_step=""
current_task=""
current_depends=""
current_type="delegate"
current_dir=""
in_task=false

flush_step() {
    if [[ -n "$current_step" ]]; then
        # Trim leading/trailing whitespace from task
        current_task="$(echo "$current_task" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [[ -z "$current_task" ]]; then
            echo "ERROR: Step '${current_step}' has no task description." >&2
            exit 1
        fi
        STEP_NAMES+=("$current_step")
        STEP_TASKS+=("$current_task")
        STEP_DEPENDS+=("$current_depends")
        STEP_TYPES+=("$current_type")
        STEP_DIRS+=("${current_dir:-$GLOBAL_WORKING_DIR}")
    fi
    current_step=""
    current_task=""
    current_depends=""
    current_type="delegate"
    current_dir=""
    in_task=false
}

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines at top level
    [[ "$line" =~ ^#[^#] ]] && continue
    [[ "$line" =~ ^---$ ]] && break  # Stop at notes section

    # Global working_dir (before any step)
    if [[ ${#STEP_NAMES[@]} -eq 0 ]] && [[ -z "$current_step" ]]; then
        if [[ "$line" =~ ^working_dir:[[:space:]]*(.*) ]]; then
            GLOBAL_WORKING_DIR="${BASH_REMATCH[1]}"
            continue
        fi
    fi

    # Step header
    if [[ "$line" =~ ^##[[:space:]]+step:[[:space:]]*(.*) ]]; then
        flush_step
        current_step="${BASH_REMATCH[1]}"
        continue
    fi

    # Inside a step: parse fields
    if [[ -n "$current_step" ]]; then
        if [[ "$line" =~ ^depends_on:[[:space:]]*(.*) ]]; then
            current_depends="${BASH_REMATCH[1]}"
            in_task=false
            continue
        fi
        if [[ "$line" =~ ^type:[[:space:]]*(.*) ]]; then
            current_type="${BASH_REMATCH[1]}"
            in_task=false
            continue
        fi
        if [[ "$line" =~ ^working_dir:[[:space:]]*(.*) ]]; then
            current_dir="${BASH_REMATCH[1]}"
            in_task=false
            continue
        fi
        if [[ "$line" =~ ^task:[[:space:]]*(.*) ]]; then
            current_task="${BASH_REMATCH[1]}"
            in_task=true
            continue
        fi
        # Continuation lines for task
        if [[ "$in_task" == true ]] && [[ -n "$line" ]]; then
            current_task="${current_task}"$'\n'"${line}"
            continue
        fi
    fi
done < "$PLAN_FILE"

# Flush last step
flush_step

NUM_STEPS=${#STEP_NAMES[@]}

if [[ "$NUM_STEPS" -eq 0 ]]; then
    echo "ERROR: No steps found in plan file." >&2
    exit 1
fi

# --- Validate ---

# Check for duplicate step names
declare -A seen_names
for name in "${STEP_NAMES[@]}"; do
    if [[ -v "seen_names[$name]" ]]; then
        echo "ERROR: Duplicate step name: ${name}" >&2
        exit 1
    fi
    seen_names["$name"]=1
done

# Check dependencies reference valid steps
for i in "${!STEP_DEPENDS[@]}"; do
    dep="${STEP_DEPENDS[$i]}"
    if [[ -n "$dep" ]] && [[ ! -v "seen_names[$dep]" ]]; then
        echo "ERROR: Step '${STEP_NAMES[$i]}' depends on unknown step '${dep}'." >&2
        exit 1
    fi
done

# Check all steps have a working directory
for i in "${!STEP_NAMES[@]}"; do
    if [[ -z "${STEP_DIRS[$i]}" ]]; then
        echo "ERROR: Step '${STEP_NAMES[$i]}' has no working_dir (and no global default)." >&2
        exit 1
    fi
done

# --- Print plan ---

log() {
    [[ "$QUIET" == false ]] && echo "$@" >&2
}

log "=== Workflow: ${NUM_STEPS} steps ==="
for i in "${!STEP_NAMES[@]}"; do
    dep_info=""
    [[ -n "${STEP_DEPENDS[$i]}" ]] && dep_info=" (after: ${STEP_DEPENDS[$i]})"
    log "  [$((i+1))] ${STEP_NAMES[$i]}${dep_info} [${STEP_TYPES[$i]}]"
done
log ""

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run -- plan parsed successfully. ${NUM_STEPS} steps."
    for i in "${!STEP_NAMES[@]}"; do
        echo ""
        echo "Step $((i+1)): ${STEP_NAMES[$i]}"
        echo "  Type: ${STEP_TYPES[$i]}"
        echo "  Dir:  ${STEP_DIRS[$i]}"
        [[ -n "${STEP_DEPENDS[$i]}" ]] && echo "  After: ${STEP_DEPENDS[$i]}"
        echo "  Task: ${STEP_TASKS[$i]}"
    done
    exit 0
fi

# --- Execute steps ---

# Create a workflow artifact directory
WORKFLOW_ID="$(date -u +%Y%m%d-%H%M%S)-workflow"
WORKFLOW_DIR="${PROJECT_ROOT}/artifacts/${WORKFLOW_ID}"
mkdir -p "$WORKFLOW_DIR"

# Track step results: step_name -> task_id
declare -A STEP_TASK_IDS
declare -A STEP_STATUSES

WORKFLOW_FAILED=false

for i in "${!STEP_NAMES[@]}"; do
    STEP_NAME="${STEP_NAMES[$i]}"
    STEP_TASK="${STEP_TASKS[$i]}"
    STEP_TYPE="${STEP_TYPES[$i]}"
    STEP_DIR="${STEP_DIRS[$i]}"
    STEP_DEP="${STEP_DEPENDS[$i]}"

    log "--- Step $((i+1))/${NUM_STEPS}: ${STEP_NAME} ---"

    # Check if dependency failed
    if [[ -n "$STEP_DEP" ]]; then
        DEP_STATUS="${STEP_STATUSES[$STEP_DEP]:-unknown}"
        if [[ "$DEP_STATUS" != "completed" ]]; then
            log "SKIPPED: dependency '${STEP_DEP}' did not complete (status: ${DEP_STATUS})."
            STEP_STATUSES["$STEP_NAME"]="skipped"
            echo "skipped (dependency '${STEP_DEP}' ${DEP_STATUS})" > "${WORKFLOW_DIR}/${STEP_NAME}.status"
            continue
        fi
    fi

    # Build delegate command
    DELEGATE_ARGS=(-d "$STEP_DIR" -t "$TIMEOUT" -s "${STEP_NAME}" -q)
    [[ -n "$MODEL" ]] && DELEGATE_ARGS+=(-m "$MODEL")

    # Pass dependency result as context
    if [[ -n "$STEP_DEP" ]]; then
        DEP_TASK_ID="${STEP_TASK_IDS[$STEP_DEP]}"
        DEP_RESULT="${PROJECT_ROOT}/artifacts/${DEP_TASK_ID}/result.md"
        if [[ -f "$DEP_RESULT" ]]; then
            DELEGATE_ARGS+=(-c "$DEP_RESULT")
        fi
    fi

    # Execute
    STEP_EXIT=0
    if [[ "$STEP_TYPE" == "review" ]]; then
        # Review steps use review-with-codex.sh
        REVIEW_ARGS=(-d "$STEP_DIR" -s "${STEP_NAME}" -q --uncommitted)
        TASK_ID="$("${SCRIPT_DIR}/review-with-codex.sh" "${REVIEW_ARGS[@]}")" || STEP_EXIT=$?
    else
        # Normal delegation
        TASK_ID="$(echo "$STEP_TASK" | "${SCRIPT_DIR}/delegate.sh" "${DELEGATE_ARGS[@]}" -- -)" || STEP_EXIT=$?
    fi

    STEP_TASK_IDS["$STEP_NAME"]="$TASK_ID"

    if [[ "$STEP_EXIT" -eq 0 ]]; then
        STEP_STATUSES["$STEP_NAME"]="completed"
        log "COMPLETED: ${STEP_NAME} -> ${TASK_ID}"
    else
        STEP_STATUSES["$STEP_NAME"]="failed"
        log "FAILED: ${STEP_NAME} -> ${TASK_ID} (exit: ${STEP_EXIT})"
        WORKFLOW_FAILED=true
    fi

    # Record in workflow dir
    echo "${STEP_STATUSES[$STEP_NAME]}" > "${WORKFLOW_DIR}/${STEP_NAME}.status"
    echo "$TASK_ID" > "${WORKFLOW_DIR}/${STEP_NAME}.task_id"
done

# --- Workflow summary ---

log ""
log "=== Workflow Summary ==="

# Write summary file
{
    echo "# Workflow: ${WORKFLOW_ID}"
    echo ""
    echo "| Step | Status | Task ID |"
    echo "|------|--------|---------|"
    for i in "${!STEP_NAMES[@]}"; do
        NAME="${STEP_NAMES[$i]}"
        STATUS="${STEP_STATUSES[$NAME]:-unknown}"
        TID="${STEP_TASK_IDS[$NAME]:-n/a}"
        echo "| ${NAME} | ${STATUS} | ${TID} |"
        log "  ${NAME}: ${STATUS} (${TID})"
    done
} > "${WORKFLOW_DIR}/summary.md"

echo "$WORKFLOW_ID"

if [[ "$WORKFLOW_FAILED" == true ]]; then
    log ""
    log "Workflow completed with failures."
    exit 1
fi

log ""
log "Workflow completed successfully."
exit 0
