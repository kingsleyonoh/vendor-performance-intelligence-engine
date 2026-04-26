# Vendor Performance Intelligence Engine — Git Rules

> Split from `CODING_STANDARDS.md` to keep the core rules file under 10K chars.

## Git Commit Convention

**Format:** `type(scope): descriptive message`

| Type | When to use |
|------|------------|
| `feat` | New feature or functionality |
| `fix` | Bug fix |
| `refactor` | Code restructuring without behavior change |
| `test` | Adding or updating tests |
| `docs` | Documentation changes |
| `chore` | Tooling, workflows, config, dependencies |
| `style` | Formatting, whitespace, no logic change |

**Scope** = the module, app, or area affected (e.g., `scoring`, `ingestion`, `alerts`, `reports`, `auth`, `ecosystem`).

**Rules:**
- Subject line max 72 characters.
- Use imperative mood: "add filter" not "added filter".
- Reference the `[BUG]`/`[FIX]`/`[FEATURE]` from `progress.md` when applicable.
- One commit per completed item. Don't bundle unrelated changes.

**Examples (VPI-flavored):**
```
feat(scoring): implement composite_scorer with time decay
fix(ingestion): guard against missing source_event_id in vendor_resolver
refactor(alerts): extract capture_payload into lib/alerts
test(reports): add tenant-leakage tests for vendor_scorecard PDF template
docs(context): update CODEBASE_CONTEXT.md with ingestion_runs schema
chore(docker): add pg_partman to postgres image
```

## Git Branching Strategy
See `CODING_STANDARDS_META.md` — "Git Branching Strategy" for the two-branch model (`main` / `dev`).

## Respect .gitignore (CRITICAL — Prevents Accidental Exposure)
- **NEVER run `git add -f` on ANY file.** If a file is gitignored, it is gitignored ON PURPOSE.
- `docs/progress.md`, `docs/build-journal/`, `docs/architect_journal.md`, `.agent/workflows/`, `.agent/guides/`, `.agent/agents/`, `.agent/.last-sync`, `.yolo/`, `.claude/`, and PRD files are LOCAL working files (tracked during dev via the `⚠️ TRACKED DURING DEV` pattern, stripped by `/prepare-public`). They must NEVER end up in a public release.
- **Proprietary files are tracked during development** so all platforms can reference them. `.gitignore` has commented-out entries marked `⚠️ TRACKED DURING DEV` — this is the default. Run `/prepare-public` before making the repo public.
- If `git status` doesn't show a file as staged after `git add .`, that means `.gitignore` is working correctly. **Do not "fix" it.**
- The ONLY acceptable staging command is `git add .` (which respects `.gitignore`).
