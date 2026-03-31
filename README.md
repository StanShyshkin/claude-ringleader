# Claude + Codex + Gemini: Multi-Agent Coding Orchestration

A shell-based system where **Claude Code acts as the foreman** and **Codex CLI and Gemini CLI run as background workers** for bounded implementation tasks. No framework, no dependencies beyond the CLIs -- just bash scripts and file-based handoff.

## Why

You talk to Claude. Claude plans, decomposes, and reviews. When there's a scoped implementation task -- write a function, fix a test, review a diff -- Claude delegates it to Codex or Gemini in the background and reads the result back. For important work, both providers review each other's output. You never switch tools.

## Architecture

```
You <──> Claude Code (foreman: plans, reviews, decides)
              │
              ├── delegate.sh ──> codex exec  ──┐
              │                                  ├── artifacts/{task-id}/
              ├── delegate.sh ──> gemini -p   ──┘     task.md, result.md,
              │                                       status, meta.json
              ├── workflow.sh ──> multi-step plans (parallel, mixed providers)
              ├── poll.sh ──────> checks task status
              ├── result.sh ────> reads task output
              ├── cost.sh ──────> aggregates token usage
              └── worker-status.sh ──> rate limit monitoring
```

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (installed and authenticated)
- [Codex CLI](https://github.com/openai/codex) (`npm install -g @openai/codex`, authenticated)
- [Gemini CLI](https://github.com/google-gemini/gemini-cli) (`npm install -g @google/gemini-cli`, authenticated) -- optional but recommended
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
For task delegation to Codex/Gemini, see ~/path/to/claude-codex-orchestrator/CLAUDE.md
```

Claude Code reads this and knows the full delegation system.

## Usage

### Delegate a Task

```bash
# Default (Codex)
delegate.sh -d /path/to/project "Implement input validation in src/api/users.ts"

# Use Gemini instead
delegate.sh -w gemini -d /path/to/project "Implement input validation"

# Async -- fire and check later
delegate.sh -d /path/to/project "Fix the failing tests"   # via run_in_background
cat .last-task-id                                           # get task ID immediately
poll.sh TASK_ID                                             # check status
result.sh TASK_ID                                           # read output
```

### Cross-Provider QA

Have one provider implement and the other review:

```bash
TASK=$(delegate.sh -w codex -d /project "Implement auth middleware")
delegate.sh -w gemini -d /project -c artifacts/$TASK/result.md "Review this implementation"
```

### Review Code

```bash
review-with-codex.sh --uncommitted -d /path/to/project
review-with-codex.sh --base main -d /path/to/project
review-with-codex.sh --commit abc123 -d /path/to/project
```

### Run a Multi-Step Workflow

```markdown
# Plan: Add user auth

working_dir: /path/to/project

## step: schema
worker: codex
task: Create the users table migration

## step: middleware
worker: gemini
depends_on: schema
task: Implement JWT auth middleware

## step: review
worker: codex
depends_on: middleware
task: Review the auth middleware implementation
```

```bash
workflow.sh plan.md                  # execute (parallel when possible)
workflow.sh --dry-run plan.md        # preview wave assignments
```

Steps without dependencies run in parallel (wave-based execution). Each step can specify its own `worker:` and `model:`.

### All delegate.sh Options

```
delegate.sh [OPTIONS] TASK_DESCRIPTION
delegate.sh [OPTIONS] -                    # read task from stdin

  -d DIR       Working directory (default: cwd)
  -t SECONDS   Timeout (default: 300)
  -m MODEL     Override model (e.g. gpt-5.4-mini, gemini-2.5-flash)
  -w WORKER    Worker: codex (default), gemini
  -r N         Retry up to N times on failure
  -S FILE      JSON schema for structured output
  -a DIR       Extra writable directory (repeatable)
  -c FILE      Context file to include (repeatable)
  -s SLUG      Custom slug for task ID
  -q           Quiet mode
```

### Management

```bash
list-tasks.sh                         # all tasks
list-tasks.sh --running               # running only
cost.sh --today                       # token usage today
cost.sh --no-cost                     # tokens only (skip dollar estimates)
worker-status.sh                      # check rate limit status
worker-status.sh --clear              # clear all lockouts
cleanup.sh --days 3                   # remove old artifacts
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
| `worker-status.sh` | Check/clear rate limit lockouts |

## Workers

Workers live in `bin/workers/`. Each implements a standard interface:

| Worker | Backend | Status |
|---|---|---|
| `codex.sh` | Codex CLI via `codex exec` | Working |
| `codex-review.sh` | Codex CLI via `codex review` | Working |
| `gemini.sh` | Gemini CLI via headless mode (`gemini -p`) | Working |

### Model Selection

**Codex** (`-w codex`, default):

| Model | Best For |
|---|---|
| `gpt-5.4` | Default. Complex tasks, multi-file changes |
| `gpt-5.4-mini` | Simple fixes, cleanup, renames |
| `gpt-5.3-codex` | Complex software engineering |

**Gemini** (`-w gemini`):

| Model | Best For |
|---|---|
| `gemini-3.1-pro-preview` | Default (Pro). Most capable coding model |
| `gemini-3-flash-preview` | Fast general-purpose coding |
| `gemini-2.5-pro` | Web development, long-context tasks |
| `gemini-2.5-flash` | Simple tasks, quick responses |

To add a new worker, create `bin/workers/<name>.sh` following the interface in `codex.sh`, then use `delegate.sh -w <name>`.

## Rate Limit Handling

When a worker hits a rate limit (429), delegate.sh automatically detects it and writes a lockout file. Subsequent calls to that worker fail fast with a clear error instead of wasting time. Use `worker-status.sh` to check status or switch to the other provider.

## Artifacts

Each task produces `artifacts/{task-id}/`:

| File | Content |
|---|---|
| `task.md` | Original task with YAML metadata |
| `prompt.md` | Full prompt sent to worker (template + task + context) |
| `result.md` | Worker's final output |
| `status` | `running`, `completed`, or `failed` |
| `meta.json` | Timing, worker, exit code, token usage, model |
| `stderr.log` | Error output (empty on success) |
| `exit_code` | Numeric exit code |

Event logs: `logs/{task-id}.jsonl`

## Claude Code Plugin

This repo includes Claude Code plugin structure for distribution:
- `.claude-plugin/plugin.json` -- plugin metadata
- `skills/delegate/SKILL.md` -- model-invoked skill (auto-teaches Claude about delegation)
- `commands/` -- slash commands (`/delegate`, `/codex-review`, `/tasks`, `/cost`)
- `ORCHESTRATOR_DATA_DIR` env var support for portable artifact storage

## Design Principles

- **Simple bash, no framework.** Every script is readable and self-contained.
- **File-based handoff.** All state lives in artifact directories. No databases, no daemons.
- **Multi-provider.** Codex and Gemini as equal workers. Claude as foreman and arbiter.
- **Fail loudly.** `set -euo pipefail` everywhere. Errors are visible, not swallowed.
- **Easy to debug.** Re-run any command manually. Inspect any artifact with `cat`.
- **Stateless scripts.** No persistent processes. Each invocation is independent.
- **Local-first.** No cloud services, no external dependencies beyond the CLIs.

## License

MIT
