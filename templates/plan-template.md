# Plan: <title>

working_dir: /absolute/path/to/project

## step: <step-name>
task: <one-line or multi-line task description. Multi-line tasks are all
lines between "task:" and the next field or step header.>

## step: <step-name>
depends_on: <previous-step-name>
task: <description. This step receives the result of its dependency as context.>

## step: <step-name>
depends_on: <step-name>
type: review
task: Review all changes from previous steps.

---

NOTES:
- Each step is delimited by "## step: <name>"
- "working_dir:" at top level sets the default for all steps
- Steps can override with their own "working_dir:" field
- "depends_on:" makes a step wait and receive the dependency's result as context
- "type: review" uses review-with-codex.sh instead of delegate.sh
- Steps without depends_on run in the order they appear
- Step names must be unique within a plan
