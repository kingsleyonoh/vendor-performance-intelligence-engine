# YOLO Inbox

> **Drop your thoughts here while YOLO is running.** The master picks up new entries between batches and treats them as work to fold into the next batch (or, for HIGH-priority entries, intercept the next batch entirely). After YOLO handles an entry, it moves to `## Handled` with batch + commit reference. Both sections are git-tracked so you can audit any commit back to the concern that triggered it.
>
> **You can write entries yourself, OR brief a separate Claude / Codex / Antigravity instance:**
> *"YOLO is running on this project. I noticed [concern]. Add an inbox entry."*
> The agent follows `.agent/workflows/yolo-feedback.md` — read-only inspection of the running YOLO state, then a single append to this file. It modifies nothing else.

---

## How master picks priority

Each new entry under `## Pending` is read at the next batch boundary. Master classifies priority itself unless you've tagged the title explicitly with `[HIGH]` / `[MEDIUM]` / `[LOW]`:

| Priority | Trigger | Behavior |
|----------|---------|----------|
| **HIGH** | Entry contains explicit urgency words (`blocks`, `urgent`, `before next batch`, `stop`, `critical`) OR title tagged `[HIGH]` OR concern contradicts a current invariant from `progress.md` | **Intercept** — next batch becomes an inbox-batch handling this entry first |
| **MEDIUM** *(default)* | Entry proposes a refactor, abstraction extraction, or addresses recently-committed code without urgency words | **Fold** — master picks the next batch whose tag/module overlaps the entry and absorbs it; if no overlap in 3 batches, runs as its own batch |
| **LOW** | Entry is style / naming / documentation / nice-to-have | **Defer** — noted for the phase-end sweep batch |

Default is MEDIUM, not HIGH — interrupting planned work on every captured thought defeats autonomous mode. Tag `[HIGH]` in the title if you really do want immediate intercept.

## Refactor intent

Entries whose wording is purely structural — `extract`, `rename`, `consolidate`, `behind an interface`, `dedupe`, `move`, `inline` — get the `refactor_intent` flag. The implement sub-agent's pure-refactor exception applies (no theatrical RED test for "interface exists"; behavior preservation is enforced by REGRESSION staying green).

---

## Pending

<!-- New entries go here. Use the format below. Master is tolerant of missing fields, but more structure = better fix.

### [HIGH|MEDIUM|LOW (optional)] Title — YYYY-MM-DD

**Concern:** Why this matters. What you saw, what risk it creates.
**Suggested fix:** Optional — if you have a specific approach in mind. Master will figure it out from the concern otherwise.
**Affected files:** Optional — paths if you know them. The yolo-feedback workflow verifies these exist before writing.
**Batch source:** Optional — which batch introduced the concern (e.g. `batch 023`). The yolo-feedback workflow finds this via git log if you don't know.
**Existing pattern:** Optional — link to `.agent/knowledge/foundation/foo.md` or `patterns/NNN-bar.md` if a similar pattern exists in the project.
**Type:** Optional — FIX | FEATURE | BUG | REFACTOR. Master infers if missing.

Status: PENDING
-->

(empty)

---

## Handled

<!-- Master moves entries from ## Pending here after the inbox-batch commits. Format:

### [Original title] — YYYY-MM-DD
*Original concern preserved verbatim — see git history for full original entry.*

**Handled by:** batch NNN
**Commit:** [short hash] [conventional commit message]
**Date handled:** YYYY-MM-DD
**Approach taken:** One-line summary of what the implement sub-agent did. Cross-reference to the batch journal entry at `docs/build-journal/NNN-batch.md` for full narrative.

---
-->

(none yet)
