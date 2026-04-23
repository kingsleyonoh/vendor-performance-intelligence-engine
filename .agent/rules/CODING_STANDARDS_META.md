# Vendor Performance Intelligence Engine — Coding Standards: Meta (Skills, Environment, Branching)

> Part 2 of 5. Also loaded: `CODING_STANDARDS.md` (core AI discipline), `CODING_STANDARDS_TESTING.md` (core TDD), `CODING_STANDARDS_TESTING_LIVE.md` (mock policy + component + backend integration), `CODING_STANDARDS_TESTING_E2E.md` (E2E), `CODING_STANDARDS_DOMAIN.md` (deploy/security)
> This file covers skill orchestration, shell environment, and git branching strategy. The main AI discipline rules live in `CODING_STANDARDS.md`.

## Skill Selection & Orchestration

You have a vast library of specialized skills available. **Use them proactively** — don't wing it when a skill exists for the task.

### How Skill Selection Works
1. **Before starting any implementation task**, mentally scan your available skills for matches.
2. If a relevant skill exists, **read its SKILL.md first**, then follow its guidance.
3. **Announce your choice**: *"I am invoking the [skill-name] skill to ensure this follows best practices."*
4. When multiple skills could apply, invoke the most specific one (e.g., `react-patterns` over `frontend-design` for a React component).
5. **When in doubt, invoke the skill.** Reading a SKILL.md costs 30 seconds. Getting it wrong costs hours.

### When to Invoke Skills (Non-Negotiable)
- **Building with a specific framework/library** → find the matching skill (React, Next.js, Django, FastAPI, etc.)
- **Touching security** (auth, input validation, secrets, API exposure) → invoke a security skill
- **Writing tests** → invoke the testing skill for your language/framework
- **Designing a database schema or API** → invoke the design/architecture skill
- **Debugging a bug** → invoke `systematic-debugging` before guessing
- **Deploying or containerizing** → invoke the deployment skill for your platform
- **Integrating a payment provider, email service, or external API** → check for a dedicated skill first
- **Working with AI/LLM features** → invoke the relevant AI skill (RAG, agents, prompts)
- **Writing documentation** → invoke the documentation skill for the format you need
- **Unfamiliar domain or new library** → research skill first, then build

### What NOT to Do
- ❌ Skip skills because "I already know this" — the skill may have guardrails you'd miss
- ❌ Hardcode patterns from memory when a skill has the latest best practices
- ❌ Use a generic approach when a project-specific skill exists

### Use Skills When Available (Skills > Pre-trained Knowledge)
- Before implementing any task, scan your available skills list for domain matches.
- If a matching skill exists (e.g., database → `postgresql`, auth → `auth-implementation-patterns`, payments → `stripe-integration`), read its `SKILL.md` and follow its instructions.
- **CRITICAL:** The patterns, architectures, and rules defined in a `SKILL.md` STRICTLY OVERRIDE your general pre-trained knowledge. Always choose the skill's approach over what you "think you know."
- **Always announce:** *"Using skill: [skill-name] for this task."* so the user knows which patterns are being applied.
- If no skill matches, proceed normally.

## Shell / Ruby Environment
- **Bash-flavored shell on Windows.** Use Unix syntax: `/dev/null`, forward slashes, `export VAR=`.
- **Ruby 3.3 via rbenv / rvm / asdf** — match `.ruby-version` in the repo root. Run `ruby -v` to verify before `bundle` commands.
- **Always `bundle exec`** for project-scoped Ruby tools (`bundle exec rails`, `bundle exec rubocop`, `bundle exec rspec` — though VPI uses Minitest via `bin/rails test`).
- **Prefer `bin/` wrappers** — `bin/rails`, `bin/dev`, `bin/rake`. These pin versions via Bundler's binstubs and won't silently pick up a system gem.
- Use `;` to chain shell commands when using PowerShell; use `&&` in bash. **Do not mix.**
- **NEVER use inline `ruby -e "..."`** for complex code. Write a `.rb` file or a rake task in `lib/tasks/`.
- For Docker Compose local services: `docker compose up -d postgres redis` — never commit `.env` with real secrets; use `.env.example` + placeholder values.

## Git Branching Strategy

### Two-Branch Model
- **`main`** — Production only. Code merges here when ready to deploy.
- **`dev`** — Active development. All work happens here.
- `/implement-next` always runs on `dev`.
- Tests always run against local dev services on `dev` branch.
- Merge `dev` → `main` only when all tests pass and feature is complete.
- After merge, run migrations against production.
