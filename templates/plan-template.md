# Plan: <title>

working_dir: /absolute/path/to/project

## step: <step-name>
task: <one-line or multi-line task description. Multi-line tasks are all
lines between "task:" and the next field or step header.>

## step: <step-name>
depends_on: <previous-step-name>
task: <description. This step receives the result of its dependency as context.>

## step: <step-name>
depends_on: <step-a>, <step-b>
task: <depends on multiple steps. Receives all dependency results as context.>

## step: <step-name>
worker: gemini
model: gemini-2.5-flash
task: <simple task using a specific worker and model>

## step: <step-name>
depends_on: <step-name>
type: review
task: Review all changes from previous steps.

## Cross-provider QA example:

## step: implement
worker: codex
task: Implement the feature

## step: review-by-gemini
worker: gemini
depends_on: implement
task: Review the implementation. List issues, edge cases, security concerns.

---

NOTES:
- Each step is delimited by "## step: <name>"
- "working_dir:" at top level sets the default for all steps
- Steps can override with their own "working_dir:" field
- "depends_on:" supports comma-separated values for multiple dependencies
- A step waits for all dependencies and receives their results as context
- "worker:" sets the worker per step (codex or gemini; default: codex)
- "model:" overrides the model per step (e.g., gpt-5.4-mini, gemini-2.5-flash)
- "type: review" uses review-with-codex.sh instead of delegate.sh
- Steps without dependencies run in parallel (wave-based execution)
- Steps in the same wave start concurrently
- Step names must be unique within a plan
