---
description: Delegate a bounded task to Codex CLI
argument-hint: [-d DIR] [-t TIMEOUT] [-r N] [-S SCHEMA] TASK
allowed-tools: [Bash, Read, Glob]
---

Delegate a task to Codex using the orchestration scripts.

Run: `${CLAUDE_PLUGIN_ROOT}/bin/delegate.sh` with the user's arguments.

The script prints the TASK_ID as its last stdout line. Use `${CLAUDE_PLUGIN_ROOT}/bin/result.sh TASK_ID` to read the result.

For async execution, use `run_in_background: true` on the Bash tool, then poll with `${CLAUDE_PLUGIN_ROOT}/bin/poll.sh TASK_ID`.
