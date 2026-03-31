---
description: Run code review via Codex CLI
argument-hint: [--uncommitted|--base BRANCH|--commit SHA] [-d DIR]
allowed-tools: [Bash, Read]
---

Delegate a code review to Codex.

Run: `${CLAUDE_PLUGIN_ROOT}/bin/review-with-codex.sh` with the user's arguments.

Supports `--uncommitted`, `--base BRANCH`, or `--commit SHA` to specify review scope.
