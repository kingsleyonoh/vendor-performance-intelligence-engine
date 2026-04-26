# Vendor Performance Intelligence Engine — Workflow Rules

> Split from `CODING_STANDARDS.md` to keep the core rules file under 10K chars.

## Workflow Pipeline Awareness
- After completing ANY workflow, **read `.agent/workflows/PIPELINE.md`** and suggest the NEXT logical workflow based on the current context.
- **PIPELINE.md is the single source of truth** for "what comes next." Individual workflows do NOT hardcode their next step — they defer to PIPELINE.md.
- Never leave the user guessing what to do next. Always end with a clear next step.
- **When creating a NEW workflow file**, ALWAYS add it to `PIPELINE.md` with its "When Done, Suggest" message.
- **When deleting a workflow file**, ALWAYS remove it from `PIPELINE.md`.
- `PIPELINE.md` must ALWAYS match the actual files in `.agent/workflows/`. If they're out of sync, fix `PIPELINE.md` immediately.

## Workflow Approval Gates (CRITICAL — Prevents Plan Mode Errors)
When a workflow step says "present to user", "wait for approval", or "approve before proceeding":
1. Present the content directly as **formatted text in the conversation**.
2. End with a clear question: `Approve? [yes / no / edit]`
3. Wait for the user's response before proceeding to the next step.
4. **NEVER call `ExitPlanMode` or `EnterPlanMode`** during workflow execution. These are Claude Code built-in tools for a separate system (toggled via `Shift+Tab`). Workflow approval gates are handled through direct conversation.
5. **NEVER write to `.claude/plans/`** during workflow execution — that directory is reserved for Claude Code's built-in plan mode.

This applies to ALL approval gates: batch selection, implementation plans, RED/GREEN/REGRESSION evidence, commit approval, refactor plans, and any other "present and wait" step in any workflow.
