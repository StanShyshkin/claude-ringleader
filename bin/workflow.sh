#!/usr/bin/env bash
set -euo pipefail

# workflow.sh -- Run a multi-step plan, delegating each step to codex
#
# Usage: bin/workflow.sh [OPTIONS] PLAN_FILE
#
# Options:
#   -t SECONDS   Per-step timeout (default: 300)
#   -m MODEL     Override model for all steps
#   -r N         Retry failed steps up to N times
#   --dry-run    Parse and print the plan without executing
#   -q           Quiet mode
#
# Steps without dependencies run in parallel (wave-based execution).
# Steps with depends_on wait for all dependencies to complete first.
# Plan file format: see templates/plan-template.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TIMEOUT=300
MODEL=""
RETRIES=0
DRY_RUN=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) TIMEOUT="$2"; shift 2 ;;
        -m) MODEL="$2"; shift 2 ;;
        -r) RETRIES="$2"; shift 2 ;;
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

GLOBAL_WORKING_DIR=""

STEP_NAMES=()
STEP_TASKS=()
STEP_DEPENDS=()  # comma-separated dependency list
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
    [[ "$line" =~ ^#[^#] ]] && continue
    [[ "$line" =~ ^---$ ]] && break

    if [[ ${#STEP_NAMES[@]} -eq 0 ]] && [[ -z "$current_step" ]]; then
        if [[ "$line" =~ ^working_dir:[[:space:]]*(.*) ]]; then
            GLOBAL_WORKING_DIR="${BASH_REMATCH[1]}"
            continue
        fi
    fi

    if [[ "$line" =~ ^##[[:space:]]+step:[[:space:]]*(.*) ]]; then
        flush_step
        current_step="${BASH_REMATCH[1]}"
        continue
    fi

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
        if [[ "$in_task" == true ]] && [[ -n "$line" ]]; then
            current_task="${current_task}"$'\n'"${line}"
            continue
        fi
    fi
done < "$PLAN_FILE"

flush_step

NUM_STEPS=${#STEP_NAMES[@]}

if [[ "$NUM_STEPS" -eq 0 ]]; then
    echo "ERROR: No steps found in plan file." >&2
    exit 1
fi

# --- Validate ---

declare -A seen_names
for name in "${STEP_NAMES[@]}"; do
    if [[ -v "seen_names[$name]" ]]; then
        echo "ERROR: Duplicate step name: ${name}" >&2
        exit 1
    fi
    seen_names["$name"]=1
done

# Validate dependencies (comma-separated)
for i in "${!STEP_DEPENDS[@]}"; do
    deps="${STEP_DEPENDS[$i]}"
    [[ -z "$deps" ]] && continue
    IFS=',' read -ra dep_list <<< "$deps"
    for dep in "${dep_list[@]}"; do
        dep="$(echo "$dep" | xargs)"  # trim whitespace
        if [[ ! -v "seen_names[$dep]" ]]; then
            echo "ERROR: Step '${STEP_NAMES[$i]}' depends on unknown step '${dep}'." >&2
            exit 1
        fi
    done
done

for i in "${!STEP_NAMES[@]}"; do
    if [[ -z "${STEP_DIRS[$i]}" ]]; then
        echo "ERROR: Step '${STEP_NAMES[$i]}' has no working_dir (and no global default)." >&2
        exit 1
    fi
done

# --- Compute waves for parallel execution ---

declare -A STEP_WAVE
declare -A STEP_INDEX  # name -> index

for i in "${!STEP_NAMES[@]}"; do
    STEP_INDEX["${STEP_NAMES[$i]}"]="$i"
done

# Iterative topological wave assignment
changed=true
while [[ "$changed" == true ]]; do
    changed=false
    for i in "${!STEP_NAMES[@]}"; do
        name="${STEP_NAMES[$i]}"
        [[ -v "STEP_WAVE[$name]" ]] && continue

        deps="${STEP_DEPENDS[$i]}"
        if [[ -z "$deps" ]]; then
            STEP_WAVE["$name"]=0
            changed=true
            continue
        fi

        max_dep_wave=-1
        all_resolved=true
        IFS=',' read -ra dep_list <<< "$deps"
        for dep in "${dep_list[@]}"; do
            dep="$(echo "$dep" | xargs)"
            if [[ -v "STEP_WAVE[$dep]" ]]; then
                w="${STEP_WAVE[$dep]}"
                [[ "$w" -gt "$max_dep_wave" ]] && max_dep_wave="$w"
            else
                all_resolved=false
                break
            fi
        done

        if [[ "$all_resolved" == true ]]; then
            STEP_WAVE["$name"]=$((max_dep_wave + 1))
            changed=true
        fi
    done
done

# Find max wave
MAX_WAVE=0
for w in "${STEP_WAVE[@]}"; do
    [[ "$w" -gt "$MAX_WAVE" ]] && MAX_WAVE="$w"
done

# --- Print plan ---

log() {
    [[ "$QUIET" == false ]] && echo "$@" >&2
}

log "=== Workflow: ${NUM_STEPS} steps, $((MAX_WAVE + 1)) wave(s) ==="
for wave in $(seq 0 "$MAX_WAVE"); do
    log "  Wave ${wave}:"
    for i in "${!STEP_NAMES[@]}"; do
        name="${STEP_NAMES[$i]}"
        [[ "${STEP_WAVE[$name]}" -eq "$wave" ]] || continue
        dep_info=""
        [[ -n "${STEP_DEPENDS[$i]}" ]] && dep_info=" (after: ${STEP_DEPENDS[$i]})"
        log "    ${name}${dep_info} [${STEP_TYPES[$i]}]"
    done
done
log ""

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run -- plan parsed successfully. ${NUM_STEPS} steps, $((MAX_WAVE + 1)) wave(s)."
    for wave in $(seq 0 "$MAX_WAVE"); do
        echo ""
        echo "Wave ${wave}:"
        for i in "${!STEP_NAMES[@]}"; do
            name="${STEP_NAMES[$i]}"
            [[ "${STEP_WAVE[$name]}" -eq "$wave" ]] || continue
            echo "  Step: ${name}"
            echo "    Type: ${STEP_TYPES[$i]}"
            echo "    Dir:  ${STEP_DIRS[$i]}"
            [[ -n "${STEP_DEPENDS[$i]}" ]] && echo "    After: ${STEP_DEPENDS[$i]}"
            echo "    Task: ${STEP_TASKS[$i]}"
        done
    done
    exit 0
fi

# --- Execute steps wave by wave ---

WORKFLOW_ID="$(date -u +%Y%m%d-%H%M%S)-workflow"
WORKFLOW_DIR="${PROJECT_ROOT}/artifacts/${WORKFLOW_ID}"
mkdir -p "$WORKFLOW_DIR"

declare -A STEP_TASK_IDS
declare -A STEP_STATUSES

WORKFLOW_FAILED=false

for wave in $(seq 0 "$MAX_WAVE"); do
    # Collect steps in this wave
    WAVE_STEPS=()
    for i in "${!STEP_NAMES[@]}"; do
        [[ "${STEP_WAVE[${STEP_NAMES[$i]}]}" -eq "$wave" ]] && WAVE_STEPS+=("$i")
    done

    [[ ${#WAVE_STEPS[@]} -eq 0 ]] && continue

    WAVE_SIZE=${#WAVE_STEPS[@]}
    if [[ "$WAVE_SIZE" -gt 1 ]]; then
        log "--- Wave ${wave}: ${WAVE_SIZE} steps in parallel ---"
    else
        log "--- Wave ${wave}: ${STEP_NAMES[${WAVE_STEPS[0]}]} ---"
    fi

    # Launch all steps in this wave
    declare -A WAVE_PIDS

    for i in "${WAVE_STEPS[@]}"; do
        STEP_NAME="${STEP_NAMES[$i]}"
        STEP_TASK="${STEP_TASKS[$i]}"
        STEP_TYPE="${STEP_TYPES[$i]}"
        STEP_DIR="${STEP_DIRS[$i]}"
        STEP_DEPS="${STEP_DEPENDS[$i]}"

        # Check if any dependency failed -> skip
        SKIP=false
        if [[ -n "$STEP_DEPS" ]]; then
            IFS=',' read -ra dep_list <<< "$STEP_DEPS"
            for dep in "${dep_list[@]}"; do
                dep="$(echo "$dep" | xargs)"
                DEP_STATUS="${STEP_STATUSES[$dep]:-unknown}"
                if [[ "$DEP_STATUS" != "completed" ]]; then
                    log "  SKIPPED: ${STEP_NAME} (dependency '${dep}' ${DEP_STATUS})"
                    STEP_STATUSES["$STEP_NAME"]="skipped"
                    echo "skipped" > "${WORKFLOW_DIR}/${STEP_NAME}.status"
                    echo "n/a" > "${WORKFLOW_DIR}/${STEP_NAME}.task_id"
                    echo "1" > "${WORKFLOW_DIR}/${STEP_NAME}.exit_code"
                    SKIP=true
                    break
                fi
            done
        fi
        [[ "$SKIP" == true ]] && continue

        # Launch in background subshell
        (
            # Build delegate command
            DELEGATE_ARGS=(-d "$STEP_DIR" -t "$TIMEOUT" -s "${STEP_NAME}" -q)
            [[ -n "$MODEL" ]] && DELEGATE_ARGS+=(-m "$MODEL")
            [[ "$RETRIES" -gt 0 ]] && DELEGATE_ARGS+=(-r "$RETRIES")

            # Pass all dependency results as context
            if [[ -n "$STEP_DEPS" ]]; then
                IFS=',' read -ra dep_list <<< "$STEP_DEPS"
                for dep in "${dep_list[@]}"; do
                    dep="$(echo "$dep" | xargs)"
                    DEP_TASK_ID="$(cat "${WORKFLOW_DIR}/${dep}.task_id" 2>/dev/null || echo "")"
                    if [[ -n "$DEP_TASK_ID" ]] && [[ "$DEP_TASK_ID" != "n/a" ]]; then
                        DEP_RESULT="${PROJECT_ROOT}/artifacts/${DEP_TASK_ID}/result.md"
                        [[ -f "$DEP_RESULT" ]] && DELEGATE_ARGS+=(-c "$DEP_RESULT")
                    fi
                done
            fi

            # Execute
            STEP_EXIT=0
            if [[ "$STEP_TYPE" == "review" ]]; then
                REVIEW_ARGS=(-d "$STEP_DIR" -s "${STEP_NAME}" -q --uncommitted)
                TASK_ID="$("${SCRIPT_DIR}/review-with-codex.sh" "${REVIEW_ARGS[@]}")" || STEP_EXIT=$?
            else
                TASK_ID="$(echo "$STEP_TASK" | "${SCRIPT_DIR}/delegate.sh" "${DELEGATE_ARGS[@]}" -- -)" || STEP_EXIT=$?
            fi

            # Write results to files (subshell can't modify parent vars)
            echo "${TASK_ID:-n/a}" > "${WORKFLOW_DIR}/${STEP_NAME}.task_id"
            echo "$STEP_EXIT" > "${WORKFLOW_DIR}/${STEP_NAME}.exit_code"
        ) &
        WAVE_PIDS["$STEP_NAME"]=$!
    done

    # Wait for all steps in this wave to complete
    for step_name in "${!WAVE_PIDS[@]}"; do
        wait "${WAVE_PIDS[$step_name]}" 2>/dev/null || true

        STEP_EXIT="$(cat "${WORKFLOW_DIR}/${step_name}.exit_code" 2>/dev/null || echo "1")"
        TASK_ID="$(cat "${WORKFLOW_DIR}/${step_name}.task_id" 2>/dev/null || echo "n/a")"
        STEP_TASK_IDS["$step_name"]="$TASK_ID"

        if [[ "$STEP_EXIT" -eq 0 ]]; then
            STEP_STATUSES["$step_name"]="completed"
            log "  COMPLETED: ${step_name} -> ${TASK_ID}"
        else
            STEP_STATUSES["$step_name"]="failed"
            log "  FAILED: ${step_name} -> ${TASK_ID} (exit: ${STEP_EXIT})"
            WORKFLOW_FAILED=true
        fi

        echo "${STEP_STATUSES[$step_name]}" > "${WORKFLOW_DIR}/${step_name}.status"
    done

    unset WAVE_PIDS
done

# --- Workflow summary ---

log ""
log "=== Workflow Summary ==="

{
    echo "# Workflow: ${WORKFLOW_ID}"
    echo ""
    echo "| Step | Wave | Status | Task ID |"
    echo "|------|------|--------|---------|"
    for i in "${!STEP_NAMES[@]}"; do
        NAME="${STEP_NAMES[$i]}"
        WAVE="${STEP_WAVE[$NAME]}"
        STATUS="${STEP_STATUSES[$NAME]:-unknown}"
        TID="${STEP_TASK_IDS[$NAME]:-n/a}"
        echo "| ${NAME} | ${WAVE} | ${STATUS} | ${TID} |"
        log "  ${NAME} (wave ${WAVE}): ${STATUS} (${TID})"
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
