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

# Discover the task ID (written immediately, before worker starts)
cat .last-task-id

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

### Role-Based Delegation

Use role templates to give workers domain expertise:

```bash
bin/delegate.sh -c templates/roles/security-reviewer.md -d /project "Review the auth module"
bin/delegate.sh -c templates/roles/architect.md -d /project "Review the API layer structure"
bin/delegate.sh -c templates/roles/test-writer.md -d /project "Write tests for src/utils.ts"
```

For adversarial reviews that challenge design decisions (not just correctness):

```bash
bin/delegate.sh -w gemini -c templates/adversarial-review-prompt.md -c artifacts/TASK_ID/result.md -d /project "Review this implementation"
```

Available roles: `security-reviewer`, `architect`, `test-writer`. Available review styles: `review-prompt` (standard), `adversarial-review-prompt` (challenges design decisions).

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
bin/delegate.sh -m gpt-5.4-mini -d /path/to/project "task"      # Override model
bin/delegate.sh -w codex -d /path/to/project "task"             # Explicit worker (default: codex)
bin/delegate.sh -a /path/to/shared/lib -d /project "task"       # Extra writable dir
bin/delegate.sh -c context.md -d /project "task"                # Include context file
bin/delegate.sh -t 600 -d /path/to/project "long task"          # 10 min timeout
bin/delegate.sh -r 2 -d /path/to/project "flaky task"          # Retry up to 2 times on failure
bin/delegate.sh -S templates/result-schema.json -d /project "task"  # Structured JSON output
```

Note: `-S` (structured output) is best for analysis tasks (review, summarize, classify).
For implementation tasks that modify files, use the default freeform output.

### Model Selection

Use `-m MODEL` to choose a model based on task complexity:

**Codex workers** (`-w codex`, default):

| Model | Best For | Speed |
|---|---|---|
| `gpt-5.4` | Default. Complex tasks, multi-file changes, reasoning-heavy work | Standard |
| `gpt-5.4-mini` | Simple fixes, cleanup, renames, straightforward implementation | Fast |
| `gpt-5.3-codex` | Complex software engineering, architecture-sensitive coding | Standard |

**Gemini workers** (`-w gemini`):

| Model | Best For | Speed |
|---|---|---|
| `gemini-3.1-pro-preview` | Default (Pro plan). Most capable, complex coding, on par with top models | Standard |
| `gemini-3-flash-preview` | Fast general-purpose coding, good balance | Fast |
| `gemini-2.5-pro` | Web development, long-context frontend tasks | Standard |
| `gemini-2.5-flash` | Simple tasks, quick responses | Fast |

Examples:
```bash
bin/delegate.sh -m gpt-5.4-mini -d /project "Rename variable foo to bar"
bin/delegate.sh -w gemini -d /project "Implement validation logic"
bin/delegate.sh -w gemini -m gemini-2.5-flash -d /project "Simple cleanup"
```

Omit `-m` to use the default model from `~/.codex/config.toml` (codex) or `~/.gemini/settings.json` (gemini).

Model availability changes frequently. If unsure what models are available, check `~/.codex/models_cache.json` (codex) or Gemini CLI docs (gemini). When in doubt, omit `-m`.

### Choosing a Worker

Both workers are capable. Route tasks based on strengths:

| Worker | Strengths | Best For |
|---|---|---|
| `codex` | Multi-file edits, project convention adherence, tool use | Implementation, file modifications |
| `gemini` | Large context window (1M tokens), analytical depth | Analysis, review, long-context tasks |

### Cross-Provider QA

For important work, use both providers to QA each other. Different models have different blind spots -- cross-review catches issues a single model would miss.

**Pattern 1: Implement + Cross-Review**
```bash
# Codex implements, Gemini reviews (or vice versa)
TASK=$(bin/delegate.sh -w codex -d /project "Implement the auth middleware")
bin/delegate.sh -w gemini -d /project -c artifacts/$TASK/result.md "Review the implementation described in the context. Focus on correctness, edge cases, and security. List specific issues."
```

**Pattern 2: Parallel implementation + compare**
```bash
# Both implement the same task, Claude compares
bin/delegate.sh -w codex -d /project -s auth-codex "Implement auth middleware"
bin/delegate.sh -w gemini -d /project -s auth-gemini "Implement auth middleware"
# Then read both results and pick the better approach
```

**Pattern 3: Multi-model plan review (in workflow plans)**
```markdown
## step: implement
worker: codex
task: Implement the feature

## step: review-gemini
worker: gemini
depends_on: implement
task: Review the implementation. List issues, edge cases, security concerns.

## step: review-codex
worker: codex
depends_on: implement
task: Review the implementation. Focus on correctness and test coverage.
```

Claude (Opus) remains the foreman and final arbiter -- read all reviews and decide what to act on.

### Rate Limit Handling

If a worker hits a rate limit, delegate.sh automatically detects it and locks out that worker for the cooldown period. Subsequent calls will fail fast with a clear message instead of wasting time.

```bash
bin/worker-status.sh               # Check which workers are available
bin/worker-status.sh --clear       # Clear all lockouts manually
```

When a worker is locked out, use the other worker:
```bash
# If codex is rate-limited, switch to gemini
bin/delegate.sh -w gemini -d /project "task"
```

### Workers

Workers live in `bin/workers/`. Each implements a standard interface:
- **codex.sh** -- Codex CLI via `codex exec` (default)
- **codex-review.sh** -- Codex CLI code review via `codex review`
- **gemini.sh** -- Gemini CLI via headless mode (`gemini -p`)

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
bin/cost.sh --no-cost             # Tokens only (skip dollar estimates)
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
