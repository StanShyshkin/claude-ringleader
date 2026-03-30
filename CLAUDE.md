# Multi-Agent Orchestration: Claude + Codex

This repo contains shell scripts for delegating bounded tasks to Codex CLI while Claude Code remains the foreman.

## When to Delegate

- Implementing a well-defined, scoped step (a single function, module, file, or small feature)
- Reviewing a diff or commit
- Fixing lint, test, or type errors when you already know what the errors are
- Cleanup or refactoring of a specific file or module

## When NOT to Delegate

- Planning or architecture decisions (you own those)
- Tasks requiring back-and-forth clarification with the user
- Tasks touching sensitive config, credentials, or secrets
- Tasks where you need to see intermediate results to decide next steps
- Anything where the scope is unclear or unbounded

## How to Delegate

### Synchronous (wait for result)

```bash
bin/delegate.sh -d /path/to/project "Implement the auth middleware in src/middleware/auth.ts following the existing pattern in src/middleware/logging.ts"
```

The script prints the TASK_ID as its last stdout line. It exits 0 on success, non-zero on failure.

### Asynchronous (background, check later)

Use Claude Code's `run_in_background: true` on the Bash tool, then poll:

```bash
# Start (background)
bin/delegate.sh -d /path/to/project "Implement auth middleware"

# Check status later
bin/poll.sh TASK_ID

# Read result when done
bin/result.sh TASK_ID
```

### Reading from stdin (for longer task descriptions)

```bash
echo "Detailed multi-line task description..." | bin/delegate.sh -d /path/to/project -
```

### Code Review

```bash
bin/review-with-codex.sh --uncommitted -d /path/to/project
bin/review-with-codex.sh --base main -d /path/to/project
bin/review-with-codex.sh --commit abc123 -d /path/to/project
```

### Fixing Errors

Use the fix template with delegate.sh. Paste the error output as context:

```bash
bin/delegate.sh -d /path/to/project "Fix the following test failures: <paste errors>"
```

For the fix template to be used automatically, pipe it:

```bash
cat templates/fix-prompt.md errors.txt | bin/delegate.sh -d /path/to/project -
```

### Chaining Context Between Tasks

Pass a previous task's result as context for the next task:

```bash
TASK1=$(bin/delegate.sh -d /project "Build the schema")
bin/delegate.sh -d /project -c artifacts/$TASK1/result.md "Now build the API handler using the schema from the previous step"
```

### Multi-Step Workflows

Write a plan file (see `templates/plan-template.md`) and run all steps in sequence:

```bash
bin/workflow.sh plan.md                  # Run the plan
bin/workflow.sh --dry-run plan.md        # Parse and preview without executing
bin/workflow.sh -t 600 plan.md           # 10 min timeout per step
```

Steps with `depends_on:` automatically receive their dependency's result as context. Workflow artifacts and summary are written to `artifacts/{workflow-id}/`.

### Additional delegate.sh Options

```bash
bin/delegate.sh -m gpt-4o -d /path/to/project "task"           # Override model
bin/delegate.sh -w codex -d /path/to/project "task"             # Explicit worker (default: codex)
bin/delegate.sh -a /path/to/shared/lib -d /project "task"       # Extra writable dir
bin/delegate.sh -c context.md -d /project "task"                # Include context file
bin/delegate.sh -t 600 -d /path/to/project "long task"          # 10 min timeout
bin/delegate.sh -r 2 -d /path/to/project "flaky task"          # Retry up to 2 times on failure
bin/delegate.sh -S templates/result-schema.json -d /project "task"  # Structured JSON output
```

Note: `-S` (structured output) is best for analysis tasks (review, summarize, classify).
For implementation tasks that modify files, use the default freeform output.

### Workers

Workers live in `bin/workers/`. Each implements a standard interface:
- **codex.sh** -- Codex CLI via `codex exec` (default)
- **codex-review.sh** -- Codex CLI code review via `codex review`
- **gemini.sh** -- Gemini CLI (stub, not yet implemented)

To add a new worker, create `bin/workers/<name>.sh` implementing the interface
documented in `bin/workers/codex.sh`, then use it with `bin/delegate.sh -w <name>`.

### Listing, Cleanup, and Cost

```bash
bin/list-tasks.sh                 # Show all tasks
bin/list-tasks.sh --running       # Show only running tasks
bin/list-tasks.sh --failed        # Show only failed tasks
bin/cleanup.sh --dry-run          # Preview cleanup
bin/cleanup.sh --days 3           # Remove tasks older than 3 days
bin/cost.sh                       # Aggregate token usage and cost
bin/cost.sh --today               # Today's usage only
bin/cost.sh --days 7 --json       # Last 7 days, JSON output
```

## Reading Results

```bash
bin/result.sh TASK_ID          # Human-readable output
bin/result.sh --meta TASK_ID   # Timing and exit code
bin/result.sh --json TASK_ID   # Machine-readable JSON
bin/result.sh --full TASK_ID   # Everything including event log
bin/result.sh --task TASK_ID   # Original task description
```

## Validating Results

After reading a result, check:
1. Status is `completed` (not `failed`)
2. `result.md` addresses the original task scope
3. Files that were supposed to be created/modified actually exist in the target directory
4. If applicable, run tests or linters against the changed files

If validation fails, either:
- Delegate a fix task with the specific errors
- Do the fix yourself if it's small

## Artifacts

All task artifacts live in `artifacts/{task-id}/`:
- `task.md` -- What was requested (with metadata frontmatter)
- `prompt.md` -- Full prompt sent to codex (template + task)
- `result.md` -- Codex's final message
- `status` -- `running`, `completed`, or `failed`
- `meta.json` -- Timing, PID, exit code, command, token usage
- `stderr.log` -- Error output (empty on success)
- `pid` -- Process ID (while running)
- `exit_code` -- Numeric exit code

Event logs: `logs/{task-id}.jsonl`
