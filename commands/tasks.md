---
description: List delegated tasks and their statuses
argument-hint: [--running|--completed|--failed] [--json]
allowed-tools: [Bash]
---

List all delegated tasks.

Run: `${CLAUDE_PLUGIN_ROOT}/bin/list-tasks.sh` with the user's arguments.

Supports `--running`, `--completed`, `--failed` filters and `--json` for machine-readable output.
