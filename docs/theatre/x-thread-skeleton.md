# X Thread Skeleton — vendor-performance-intelligence-engine

> **STATUS: SKELETON.** Not publishable. See `README.md` in this directory for context.

## Target output

`C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\social\x-thread\vendor-performance-intelligence-engine-thread.md`

## Audience

Engineering Twitter — likes specific failure stories with concrete details. Hooks must promise a payoff in tweet 1.

## Candidate hooks

### Hook A (snapshot freezing)

> A tenant renames itself between alert insert and Hub delivery. Your dispatcher re-queries the tenants table to "make sure the data is fresh." Now the audit log shows an alert delivered with identity that didn't exist when the alert fired.
>
> The fix isn't fresher reads. It's a frozen JSONB snapshot at insert time.
>
> Thread on legal defensibility for procurement scoring engines. 🧵

### Hook B (rules over ML)

> Procurement officers don't buy black boxes they have to defend to a CFO.
>
> I built a vendor risk scoring engine. Picked rules over gradient boosting. Every score decomposes into the top 5 contributing signals.
>
> Here's why interpretability is the product feature, not the engineering shortcut. 🧵

### Hook C (vendor name reconciliation)

> Vendor "ACME GmbH" in source A. "Acme Manufacturing GmbH" in source B. "Acme Mfg." in source C. Same vendor — three rows. Three risk scores. None of them right.
>
> The 5-rung vendor resolution ladder, and why Levenshtein-on-its-own gets you 92% there. 🧵

## Suggested arc (8-12 tweets)

For Hook A:

1. The setup (tenant rename mid-flight)
2. The naïve fix (re-query the row before send)
3. Why the naïve fix fails (audit accuracy)
4. The contract: alerts are legal documents
5. The implementation: `delivery_payload` JSONB on `risk_alerts`
6. The discipline: dispatcher reads ONLY from the snapshot
7. The test: rename tenant between insert and retry, assert original literal lands
8. The cost: storage + a strict-undefined ERB layer
9. The pattern: this same shape protects PDF reports too (`vendor_reports.render_context`)
10. Closing: "frozen snapshot at the moment of decision" as a generalizable pattern

## Anti-patterns to avoid

- Don't use ALL CAPS sentences for emphasis
- Don't use generic engineering claims ("scalable", "robust")
- No em dashes (per `references/banned_list.md`)
- Last tweet should NOT be a CTA to a paid product — link to the Foundry / Journal instead
