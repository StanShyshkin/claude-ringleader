# Claude + Codex Multi-Agent Orchestration

A shell-based system where Claude Code acts as foreman and Codex CLI runs as a background worker for bounded implementation tasks.

## Architecture

```
You <--> Claude Code (foreman)
              |
              |-- bin/delegate.sh --> codex exec (worker)
              |                           |
              |                           v
              |                    artifacts/{task-id}/
              |                       task.md     (input)
              |                       result.md   (output)
              |                       status      (running|completed|failed)
              |                       meta.json   (timing, exit code)
              |
              |-- bin/poll.sh ----> reads status
              |-- bin/result.sh --> reads result
```

## Quick Start

### Prerequisites

- Claude Code CLI (installed and authenticated)
- Codex CLI (`@openai/codex`, installed and authenticated)
- Bash 4+

### Delegate a task

```bash
# Synchronous -- wait for result
bin/delegate.sh -d /path/to/project "Create a hello world Express server in src/index.ts"

# The script prints the TASK_ID as its last stdout line
```

### Check status

```bash
bin/poll.sh 20260329-143022-create-a-hello
# Exit code: 0=completed, 1=failed, 2=running, 3=not found
```

### Read the result

```bash
bin/result.sh 20260329-143022-create-a-hello
```

### Background execution (from Claude Code)

When Claude Code delegates via `run_in_background: true`, the task runs asynchronously. Poll later to check completion.

## Scripts

| Script | Purpose |
|---|---|
| `bin/delegate.sh` | Delegate a task to Codex. Writes artifacts, invokes `codex exec`, captures output. |
| `bin/poll.sh` | Check if a task is done. Validates PID is alive if status says running. |
| `bin/result.sh` | Read task result. Supports `--json`, `--full`, `--meta`, `--task` modes. |

## Options for delegate.sh

```
bin/delegate.sh [OPTIONS] TASK_DESCRIPTION
bin/delegate.sh [OPTIONS] -          # read task from stdin

  -d DIR       Working directory for codex (default: cwd)
  -t SECONDS   Timeout in seconds (default: 300)
  -s SLUG      Custom slug for task ID
  -q           Quiet mode
```

## Artifacts

Each task produces a directory `artifacts/{task-id}/` containing:

| File | Content |
|---|---|
| `task.md` | Original task with metadata frontmatter |
| `prompt.md` | Full prompt sent to codex (template + task) |
| `result.md` | Codex's final message |
| `status` | `running`, `completed`, or `failed` |
| `meta.json` | Timing, PID, exit code, working directory |
| `stderr.log` | Error output (empty on success) |
| `pid` | Process ID while running |
| `exit_code` | Numeric exit code |

Event logs are in `logs/{task-id}.jsonl` (raw JSONL from `codex exec --json`).

## How Claude Uses This

Claude Code reads `CLAUDE.md` at session start, which teaches it:
- When to delegate (scoped implementation, reviews, fixing errors)
- When NOT to delegate (planning, architecture, ambiguous tasks)
- How to invoke the scripts and read results
- How to validate that the worker completed the requested scope

## Roadmap

- **Phase 1** (current): delegate / poll / result scripts
- **Phase 2**: code review delegation, task listing, cleanup, fix/review templates
- **Phase 3**: multi-step workflow orchestration from plan files
- **Phase 4**: worker abstraction for Gemini CLI and other providers

## Design Principles

- Simple bash scripts, no framework
- File-based handoff (artifacts directory)
- Fail loudly on errors
- Easy to inspect and debug (re-run any command manually)
- Stateless scripts (all state in artifact files)
- Local-first, no external dependencies beyond the CLIs
