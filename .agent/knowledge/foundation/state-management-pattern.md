# Foundation: State Management Pattern (UI Multi-Step Flows)

## What it establishes

VPI's Operator UI is **Hotwire** (Turbo + Stimulus + ViewComponent + Tailwind) — server-rendered HTML with Turbo Frames for partial updates and Stimulus controllers for local interaction. Multi-step flows (alias review queue, scoring-rule editor, ingestion source wizard) use **exactly one** state-management mechanism: the **server**. No client-side mini-state-machines, no localStorage drafts, no JavaScript Redux / Pinia / Zustand.

This is the project's expression of the CODING_STANDARDS_DOMAIN.md "Single State Mechanism Per Feature" rule.

## Files

- `app/views/` — layouts only (ERB)
- `app/components/` — ViewComponent classes + templates (the real rendering surface)
- `app/javascript/controllers/` — Stimulus controllers (DOM behavior only, never business state)
- Multi-step flow state: persisted to DB rows (e.g. `alias_review_sessions.step`, `scoring_rule_drafts.state`) — not held in the browser

## Contract

### The server is the source of truth

1. **Every user action that changes state** (form submit, button click) is a **server round-trip**. The server re-renders the affected Turbo Frame with new HTML.
2. **No client-side state that isn't derivable from the current DOM.** Stimulus controllers handle UI affordances (modal open/close, hover, validation preview) — never business data.
3. **No browser storage** (`localStorage`, `sessionStorage`, IndexedDB) for flow state. A user who refreshes mid-flow sees the same step because it's persisted server-side.

### Turbo Frames for partial updates

1. Each step of a wizard is its own Turbo Frame (`<turbo-frame id="alias-review-step">`). The form POSTs to a controller action that re-renders the frame with the next step.
2. Turbo Streams (broadcast over Action Cable) for server-pushed updates (e.g. "alert inbox gained 3 new items" → DOM patch without reload).
3. **Never return JSON to a Hotwire flow.** If the UI needs data, render a ViewComponent and let Turbo swap it in.

### ViewComponent for every rendering surface

1. ERB in `app/views/` is for **layouts only** (`application.html.erb`, `sidebar.html.erb`). Every individual render goes through a ViewComponent.
2. Components receive their state via the constructor (explicit inputs, no implicit globals). Makes them trivially unit-testable without a controller.
3. Multi-tenant rendering surfaces (dashboards, PDFs, emails) ALWAYS receive a `TenantSnapshot` (see PRD §5.5 / §5.6) — never a live `tenants` read and never a hardcoded literal.

### Stimulus for DOM behavior only

1. Stimulus controllers are short (< 50 lines) and handle exactly one concern: expand/collapse, debounced form preview, keyboard shortcut, copy-to-clipboard.
2. A Stimulus controller MUST NOT hold business data ("the current vendor", "the draft scoring rule"). Business data lives in the server-rendered HTML.
3. When a Stimulus interaction changes state, it submits a form (full or XHR) — the server re-renders, Turbo swaps.

## Why one mechanism

Multi-step flows that mix mechanisms (localStorage draft + server session + JS store + URL params) create race conditions where the user sees one version of the data and the server persists another. The symptom is "I saved it but it didn't save" — one of the most painful debug surfaces in webapps. Sticking to "server is truth, Turbo swaps HTML, Stimulus handles DOM" eliminates the entire class.

## When to read this

Before:
- Adding a new multi-step UI flow (alias review, rule editor, wizard)
- Reaching for localStorage / sessionStorage / a JS state library
- Creating a new Stimulus controller (check: is this DOM behavior or is it business state?)
- Building a drag-and-drop, filterable-table, or paginated-list surface

## Cross-references

- Related modules: `app/components/`, `app/javascript/controllers/`
- PRD: §5 (User Journeys), §3 (Tech Stack — UI)
- CODING_STANDARDS_DOMAIN.md — "Single State Mechanism Per Feature"
