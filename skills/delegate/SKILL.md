---
name: codex-delegate
description: Use when the user wants to delegate work to Codex, run background tasks, orchestrate multi-step workflows, review code with Codex, track task costs, or mentions multi-agent orchestration. Triggers on "delegate", "use codex", "background task", "workflow", "codex review", "cost tracking".
---

# Multi-Agent Orchestration: Claude + Codex

You are the foreman. Codex CLI is your worker for bounded implementation tasks. Use the scripts in this plugin to delegate work, track results, and manage costs.

## Quick Reference

```bash
# Delegate a task (sync)
${CLAUDE_PLUGIN_ROOT}/bin/delegate.sh -d /path/to/project "task description"

# Delegate (async via run_in_background)
${CLAUDE_PLUGIN_ROOT}/bin/delegate.sh -d /path/to/project "task"
${CLAUDE_PLUGIN_ROOT}/bin/poll.sh TASK_ID
${CLAUDE_PLUGIN_ROOT}/bin/result.sh TASK_ID

# Code review
${CLAUDE_PLUGIN_ROOT}/bin/review-with-codex.sh --uncommitted -d /path/to/project

# Multi-step workflow
${CLAUDE_PLUGIN_ROOT}/bin/workflow.sh plan.md

# List tasks / cost
${CLAUDE_PLUGIN_ROOT}/bin/list-tasks.sh
${CLAUDE_PLUGIN_ROOT}/bin/cost.sh --today
```

## When to Delegate

- Implementing a well-defined, scoped step (function, module, file, small feature)
- Reviewing a diff or commit
- Fixing lint, test, or type errors when you already know the errors
- Cleanup or refactoring of a specific file or module

## When NOT to Delegate

- Planning or architecture decisions (you own those)
- Tasks requiring back-and-forth clarification with the user
- Tasks touching sensitive config, credentials, or secrets
- Tasks where you need intermediate results to decide next steps

## delegate.sh Options

```
-d DIR       Working directory
-t SECONDS   Timeout (default: 300)
-m MODEL     Override model
-w WORKER    Worker: codex (default), gemini
-r N         Retry up to N times on failure
-S FILE      JSON schema for structured output
-a DIR       Extra writable directory (repeatable)
-c FILE      Context file (repeatable)
-q           Quiet mode
```

## Validating Results

1. Status is `completed`
2. `result.md` addresses the original task scope
3. Expected files exist in the target directory
4. Tests/linters pass if applicable

If validation fails, delegate a fix task with the specific errors, or fix it yourself if small.
