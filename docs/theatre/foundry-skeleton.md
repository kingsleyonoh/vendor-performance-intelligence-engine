# Foundry Skeleton — vendor-performance-intelligence-engine

> **STATUS: SKELETON.** Not publishable. See `README.md` in this directory for context.

## Target output

`C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\foundry\vendor-performance-intelligence-engine-foundry.md`

## Audience

CEO / Founder. Must lead with business problem and outcome FIRST. Engineer impressed second — diagrams use business labels ("Risk Scoring Engine"), not file names ("composite_scorer.rb").

## The business problem

A mid-market manufacturer with €5M+ annual vendor spend and 100+ active vendors typically loses 2-4% of vendor spend per year to unmanaged vendor risk. That's €100K-€200K/year for a €5M-spend tenant. Sources of leakage: late deliveries that cascade into expedited freight charges, missed SLA credits, contract auto-renewals on under-performing vendors, vendor consolidation opportunities never identified because nobody had the data.

Today, the signals exist but live siloed:
- Accounts payable knows which vendors ship late invoices.
- Legal operations knows which vendors breach SLA clauses.
- Integration ops knows which vendors silently drop webhook events.
- Transaction reconciliation knows which vendors have settlement variance.

A vendor that's a 1-star problem in three systems looks like three different 1-star problems instead of one 5-star vendor-to-re-tender. Quarterly post-mortems catch this six months too late.

## The cost of doing nothing

For a CPO managing a €5M vendor base, conservative cost estimate: €100K-€200K/year in preventable vendor leakage + roughly €60K-€80K of analyst time spent assembling vendor scorecards manually for the quarterly business review. Total: €160K-€280K/year.

## The outcome (what the engine produces)

- One composite risk score per vendor per tenant, refreshed continuously as new signals arrive.
- Band-crossing alerts (LOW → MEDIUM → HIGH → CRITICAL) delivered to procurement within seconds of the underlying signal that caused the crossing.
- Top-5 contributor breakdown per score — a procurement officer defending a re-tender decision to the CFO can name exactly the five signals.
- PDF scorecard reports that re-render byte-identically 30 days later for the audit committee.
- Pluggable scoring rules per tenant — a tenant in regulated chemicals weights compliance signals differently from a tenant in commodity packaging.

## High-level architecture (business-labeled)

Five concepts a non-engineer needs:

1. **Signal sources** — the four ecosystem systems plus a manual REST endpoint. Each is independently switchable.
2. **The risk scoring engine** — the brain. Takes signals, applies tenant-specific weights, produces a 0-100 composite score plus a band classification.
3. **The alert router** — listens for band crossings, captures a frozen snapshot of who-the-tenant-was at that moment, hands it to the Notification Hub for email/Telegram delivery.
4. **The reporting surface** — generates PDF scorecards, portfolio CSVs, retender candidate lists.
5. **The operator UI** — dashboards, vendor detail pages, alias-review queue, scoring-rule tuner.

## Suggested ROI framing

For a €5M-spend tenant: catching 30% of preventable vendor leakage = €30K-€60K/year direct savings. Replacing the manual quarterly scorecard assembly = €60K-€80K/year in analyst time. Total addressable savings: €90K-€140K/year per tenant. Engine itself runs on a single Hetzner VPS — operating cost €60-€120/month. Even at a 10x VPS cost the math holds.

(Validate these ranges before publishing — they're estimates.)

## Anti-patterns to avoid

- Don't claim "zero downtime" — the partition rollover is tested but month-boundary observation in production is still pending (PRD §15 #11).
- Don't claim "ML-powered" — the engine is explicitly rules-driven (PRD §2 invariant 6). ML is Phase 4.
- Don't reuse the "replaces N FTEs" closing if another foundry already used it. Check the spillover index.

## Numbers to verify before publishing

- The €5M+ annual vendor spend / 100+ active vendors target audience comes from PRD §1
- The 2-4% unmanaged vendor risk leakage estimate is industry-standard but should be sourced
- Hetzner VPS pricing: verify against current pricing
