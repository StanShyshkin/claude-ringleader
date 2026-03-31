#!/usr/bin/env bash
set -euo pipefail

# cost.sh -- Aggregate token usage and estimate cost across tasks
#
# Usage: bin/cost.sh [OPTIONS]
#
# Options:
#   --today        Tasks from today only
#   --days N       Tasks from last N days
#   --worker NAME  Filter by worker
#   --json         Machine-readable JSON output
#   --no-cost      Suppress dollar cost estimates (show tokens only)
#
# Cost rates (override via environment variables):
#   COST_INPUT_PER_M     (default: 2.50)  $/1M input tokens
#   COST_CACHED_INPUT_PER_M (default: 1.25) $/1M cached input tokens
#   COST_OUTPUT_PER_M    (default: 10.00) $/1M output tokens

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="${ORCHESTRATOR_DATA_DIR:-${PROJECT_ROOT}}"
ARTIFACTS_DIR="${DATA_DIR}/artifacts"

DAYS=""
WORKER_FILTER=""
JSON_MODE=false
NO_COST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --today)  DAYS=0; shift ;;
        --days)   DAYS="$2"; shift 2 ;;
        --worker) WORKER_FILTER="$2"; shift 2 ;;
        --json)   JSON_MODE=true; shift ;;
        --no-cost) NO_COST=true; shift ;;
        -*)       echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)        break ;;
    esac
done

# Compute date cutoff if filtering by days
CUTOFF=""
if [[ -n "$DAYS" ]]; then
    CUTOFF="$(date -u -d "${DAYS} days ago" +%Y%m%d)"
fi

# Collect matching meta.json files
META_FILES=()
for d in "$ARTIFACTS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    TASK_ID="$(basename "$d")"
    [[ "$TASK_ID" == ".gitkeep" ]] && continue

    # Date filter
    if [[ -n "$CUTOFF" ]]; then
        TASK_DATE="${TASK_ID:0:8}"
        if [[ "$TASK_DATE" =~ ^[0-9]{8}$ ]] && [[ "$TASK_DATE" -lt "$CUTOFF" ]]; then
            continue
        fi
    fi

    META_FILE="${d}meta.json"
    [[ -f "$META_FILE" ]] && META_FILES+=("$META_FILE")
done

if [[ ${#META_FILES[@]} -eq 0 ]]; then
    echo "No tasks found matching filters."
    exit 0
fi

# Pass filters to python via environment
export WORKER_FILTER="${WORKER_FILTER}"
export JSON_MODE="${JSON_MODE}"
export NO_COST="${NO_COST}"

# Aggregate using python3
python3 -c "
import json, sys, os

files = sys.argv[1:]
worker_filter = os.environ.get('WORKER_FILTER', '')
json_mode = os.environ.get('JSON_MODE', 'false') == 'true'
no_cost = os.environ.get('NO_COST', 'false') == 'true'

input_rate = float(os.environ.get('COST_INPUT_PER_M', '2.50'))
cached_rate = float(os.environ.get('COST_CACHED_INPUT_PER_M', '1.25'))
output_rate = float(os.environ.get('COST_OUTPUT_PER_M', '10.00'))

total_input = 0
total_cached = 0
total_output = 0
task_count = 0
completed = 0
failed = 0
dates = set()

for f in files:
    try:
        meta = json.load(open(f))
    except (json.JSONDecodeError, IOError):
        continue

    if worker_filter and meta.get('worker', '') != worker_filter:
        continue

    task_count += 1
    tid = meta.get('task_id', '')
    if len(tid) >= 8:
        dates.add(tid[:8])

    ec = meta.get('exit_code', -1)
    if ec == 0:
        completed += 1
    else:
        failed += 1

    usage = meta.get('token_usage', {})
    total_input += usage.get('input_tokens', 0)
    total_cached += usage.get('cached_input_tokens', 0)
    total_output += usage.get('output_tokens', 0)

# Compute cost (cached tokens replace input tokens, not additive)
net_input = total_input - total_cached
cost = (net_input * input_rate / 1_000_000) + \
       (total_cached * cached_rate / 1_000_000) + \
       (total_output * output_rate / 1_000_000)

if json_mode:
    result = {
        'tasks': task_count,
        'completed': completed,
        'failed': failed,
        'input_tokens': total_input,
        'cached_input_tokens': total_cached,
        'output_tokens': total_output,
    }
    if not no_cost:
        result['estimated_cost_usd'] = round(cost, 4)
        result['rates'] = {
            'input_per_m': input_rate,
            'cached_input_per_m': cached_rate,
            'output_per_m': output_rate
        }
    print(json.dumps(result, indent=2))
else:
    sorted_dates = sorted(dates)
    if len(sorted_dates) == 1:
        period = sorted_dates[0]
    elif len(sorted_dates) > 1:
        period = f'{sorted_dates[0]} to {sorted_dates[-1]}'
    else:
        period = 'n/a'

    print(f'Period: {period} | Tasks: {completed} completed, {failed} failed')
    print()
    print(f'  Input tokens:   {total_input:>12,}')
    print(f'  Cached tokens:  {total_cached:>12,}')
    print(f'  Output tokens:  {total_output:>12,}')
    if not no_cost:
        print()
        print(f'  Est. cost:      \${cost:>11,.4f}')
        print(f'  (rates: \${input_rate}/M input, \${cached_rate}/M cached, \${output_rate}/M output)')
" "${META_FILES[@]}"
