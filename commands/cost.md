---
description: Show token usage and cost summary across delegated tasks
argument-hint: [--today|--days N] [--worker NAME] [--json]
allowed-tools: [Bash]
---

Show aggregated token usage and estimated cost.

Run: `${CLAUDE_PLUGIN_ROOT}/bin/cost.sh` with the user's arguments.

Supports `--today`, `--days N`, `--worker NAME` filters and `--json` for machine-readable output.
