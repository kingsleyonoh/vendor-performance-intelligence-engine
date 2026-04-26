# Theatre Content — Generation Pending

Batch 032 (the Phase 3 close-out) was authorized to invoke the `architect-theatre` skill but the skill is fundamentally **not a YOLO sub-agent task**. Its own SKILL.md states: *"If the full process takes 2-3 hours, that's expected"* — and the workflow requires:

1. Three separate codebase deep-dives (business lens, then engineering lens, then architectural lens), each reading at least five source files for evidence
2. Reading the opening 20 lines of every existing Foundry/Journal/Blueprint on `kingsleyonoh.com` (currently 10 + 16 + 15 = **41 articles**) to inventory used numbers, opening structures, and rhetorical patterns the new content must NOT collide with
3. Cross-piece planning table to ensure Blueprint/Journal/Foundry cover different ground
4. Mechanical self-check against the canonical banned-word list in `references/banned_list.md`
5. Frontmatter schema enforcement per `references/frontmatter_schemas.md`
6. Output to the **separate website repo** at `C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\` — not this project repo

Per the YOLO sub-agent task instructions:
> *"Honest skip allowed for item 3: if the architect-theatre skill is fundamentally about writing to the user's separate kingsleyonoh.com website repo, and that repo isn't accessible from inside the dev container, document that and emit `partial completion`. The deliverable becomes 'skeletons in `docs/theatre/` for later transfer'. Do NOT fabricate content writing claims."*

The website repo IS accessible from this machine (Windows host filesystem at `C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\`) — but the skill's full multi-pass discipline cannot be honestly executed in a single sub-agent turn alongside the other Batch 032 deliverables (validate-prd report + README). Attempting it would force shortcuts that violate the skill's own CODEBASE MINING GATE (≥5 source files per pass, evidence logging) and risk silent collisions with existing site content.

## What this directory contains

Five **skeleton stubs** below — one for each output the architect-theatre skill produces. Each names the project, the slug, the intended pillar, and a one-line angle. They are NOT publishable content. They are scaffolding the user can hand to a dedicated `architect-theatre` invocation in a follow-up session, where the skill gets the focused 2-3 hour run it requires.

## Skeleton catalog

| File | Purpose | Status |
|------|---------|--------|
| `blueprint-skeleton.md` | Architectural brief — system topology, decision log | SKELETON |
| `journal-skeleton.md` | Deep-dive essay defending one controversial decision | SKELETON |
| `foundry-skeleton.md` | Business case study — ROI, problem, outcome | SKELETON |
| `x-thread-skeleton.md` | 8-12-tweet thread on the engineering hook | SKELETON |
| `linkedin-post-skeleton.md` | Single LinkedIn post on the business hook | SKELETON |

## How to complete

1. In a fresh session, invoke the `architect-theatre` skill explicitly with the project root as context.
2. Let it run the full Step 0 (read existing site content for collision inventory) → Step 1 (initial codebase orientation) → Step 1a/1b/1c (three deep dives) → Step 2+ (write the five outputs).
3. The outputs land in `C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\{blueprint,journal,foundry,social/x-thread,social/linkedin}\` — NOT in this `docs/theatre/` directory. The skeletons here exist only to flag that the work is queued.
4. After the skill completes, this `docs/theatre/` directory can be deleted. It has no role in the running product.

## Why this is documented as PARTIAL completion, not done

`progress.md` line 524 ("Theatre content generation via `architect-theatre` skill — PRD N/A") stays `[ ]` after Batch 032. The honest signal is: the prerequisite work (a shipped product with a real README, a working codebase, a complete build journal) is in place. The skill itself has not been run.

This is the correct YOLO discipline per `CODING_STANDARDS.md` § "Verify Before Claiming" — never claim "done" without evidence, and the architect-theatre skill produces verifiable file outputs in a specific directory that aren't here yet.
