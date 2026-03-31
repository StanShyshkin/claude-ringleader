# Claude + Codex: Multi-Agent Coding Orchestration

A shell-based system where **Claude Code acts as the foreman** and **Codex CLI runs as a background worker** for bounded implementation tasks. No framework, no dependencies beyond the CLIs -- just bash scripts and file-based handoff.

## Why

You talk to Claude. Claude plans, decomposes, and reviews. When there's a scoped implementation task -- write a function, fix a test, review a diff -- Claude delegates it to Codex in the background and reads the result back. You never switch tools.

## Architecture

```
You <──> Claude Code (foreman: plans, reviews, decides)
              │
              ├── delegate.sh ──> codex exec (worker process)
              │                        │
              │                        ▼
              │                 artifacts/{task-id}/
              │                    task.md      (input)
              │                    result.md    (output)
              │                    status       (running|completed|failed)
              │                    meta.json    (timing, tokens, exit code)
              │
              ├── workflow.sh ──> runs multi-step plans with parallel execution
              ├── poll.sh ──────> checks task status
              ├── result.sh ────> reads task output
              ├── cost.sh ──────> aggregates token usage
              └── review-with-codex.sh ──> delegates code review
```

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (installed and authenticated)
- [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`, authenticated)
- Bash 4+, Python 3 (for JSON handling in scripts)

### Setup

```bash
git clone https://github.com/YOUR_USERNAME/claude-codex-orchestrator.git
export PATH="$HOME/path/to/claude-codex-orchestrator/bin:$PATH"
```

Add the `export PATH` line to your `~/.bashrc` or `~/.zshrc` to make it permanent.

### Tell Claude Code About It

Add this line to any project's `CLAUDE.md`:

```
For task delegation to Codex, see ~/path/to/claude-codex-orchestrator/CLAUDE.md
```

Claude Code reads this and knows the full delegation system. You just talk to Claude -- "delegate this to codex" -- and it handles the rest.

## Usage

### Delegate a Task

```bash
# Synchronous -- wait for result
delegate.sh -d /path/to/project "Implement input validation in src/api/users.ts"

# Async -- fire and check later
delegate.sh -d /path/to/project "Fix the failing tests"  # via run_in_background
cat .last-task-id                                          # get the task ID immediately
poll.sh TASK_ID                                            # check status
result.sh TASK_ID                                          # read output
```

### Review Code

```bash
review-with-codex.sh --uncommitted -d /path/to/project
review-with-codex.sh --base main -d /path/to/project
review-with-codex.sh --commit abc123 -d /path/to/project
```

### Run a Multi-Step Workflow

Write a plan file:

```markdown
# Plan: Add user auth

working_dir: /path/to/project

## step: schema
task: Create the users table migration in src/db/migrations/

## step: middleware
depends_on: schema
task: Implement JWT auth middleware in src/middleware/auth.ts

## step: tests
depends_on: middleware
task: Write tests for the auth middleware
```

Run it:

```bash
workflow.sh plan.md                  # execute (steps run in parallel when possible)
workflow.sh --dry-run plan.md        # preview wave assignments without executing
```

Steps without dependencies run in parallel (wave-based execution). Steps with `depends_on` automatically receive their dependency's result as context.

### All delegate.sh Options

```
delegate.sh [OPTIONS] TASK_DESCRIPTION
delegate.sh [OPTIONS] -                    # read task from stdin

  -d DIR       Working directory (default: cwd)
  -t SECONDS   Timeout (default: 300)
  -m MODEL     Override model (e.g. gpt-4o)
  -w WORKER    Worker: codex (default), gemini
  -r N         Retry up to N times on failure
  -S FILE      JSON schema for structured output
  -a DIR       Extra writable directory (repeatable)
  -c FILE      Context file to include (repeatable)
  -s SLUG      Custom slug for task ID
  -q           Quiet mode
```

### Chain Tasks

```bash
TASK1=$(delegate.sh -d /project "Build the schema")
delegate.sh -d /project -c artifacts/$TASK1/result.md "Build the API using the schema"
```

### Management

```bash
list-tasks.sh                         # all tasks
list-tasks.sh --running               # running only
list-tasks.sh --failed                # failed only
cost.sh --today                       # token usage today
cost.sh --no-cost                     # tokens only (skip dollar estimates)
cost.sh --days 7 --json               # last 7 days, JSON output
cleanup.sh --dry-run                  # preview cleanup
cleanup.sh --days 3                   # remove artifacts older than 3 days
```

## Scripts

| Script | Purpose |
|---|---|
| `delegate.sh` | Core: delegate a task to a worker, capture all artifacts |
| `poll.sh` | Check if a task is done (exit 0=done, 1=failed, 2=running) |
| `result.sh` | Read results (`--json`, `--full`, `--meta`, `--task` modes) |
| `workflow.sh` | Run multi-step plans with parallel wave-based execution |
| `review-with-codex.sh` | Delegate code review via `codex review` |
| `list-tasks.sh` | List tasks with status, duration, filters |
| `cost.sh` | Aggregate token usage and estimate cost |
| `cleanup.sh` | Remove old artifacts (`--days N`, `--all`, `--dry-run`) |

## Workers

Workers live in `bin/workers/`. Each implements a standard interface:

| Worker | Status | Backend |
|---|---|---|
| `codex.sh` | Working | Codex CLI via `codex exec` |
| `codex-review.sh` | Working | Codex CLI via `codex review` |
| `gemini.sh` | Stub | Gemini CLI (not yet implemented) |

To add a new worker, create `bin/workers/<name>.sh` following the interface in `codex.sh`, then use `delegate.sh -w <name>`.

## Artifacts

Each task produces `artifacts/{task-id}/`:

| File | Content |
|---|---|
| `task.md` | Original task with YAML metadata |
| `prompt.md` | Full prompt sent to worker (template + task + context) |
| `result.md` | Worker's final output |
| `status` | `running`, `completed`, or `failed` |
| `meta.json` | Timing, worker, exit code, token usage |
| `stderr.log` | Error output (empty on success) |
| `exit_code` | Numeric exit code |

Event logs: `logs/{task-id}.jsonl`

## Claude Code Plugin

This repo includes Claude Code plugin structure (`.claude-plugin/`, `skills/`, `commands/`) for future distribution as an installable plugin with slash commands (`/delegate`, `/codex-review`, `/tasks`, `/cost`).

## Design Principles

- **Simple bash, no framework.** Every script is readable and self-contained.
- **File-based handoff.** All state lives in artifact directories. No databases, no daemons.
- **Fail loudly.** `set -euo pipefail` everywhere. Errors are visible, not swallowed.
- **Easy to debug.** Re-run any command manually. Inspect any artifact with `cat`.
- **Stateless scripts.** No persistent processes. Each invocation is independent.
- **Local-first.** No cloud services, no external dependencies beyond the CLIs.

## License

MIT
