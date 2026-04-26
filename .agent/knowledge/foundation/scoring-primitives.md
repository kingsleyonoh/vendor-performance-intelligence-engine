# Foundation: Scoring Primitives — SignalScalers + TimeDecay

## What it establishes

Two pure-function modules under `lib/scoring/` that the composite scorer (PRD §5.4) composes into the 0..100 risk score per vendor per tenant. Both modules are deliberately pure (no DB, no Rails, no `Current.tenant`) so they are unit-testable in isolation and safely reusable from preview endpoints, ingestion validators, and rake tasks.

- `Scoring::SignalScalers.scale(value:, value_type:, direction:, min_value:, max_value:)` — normalizes a raw value into a 0..100 contribution. Value-types: `rate`, `count`, `duration_seconds`, `money_cents`, `boolean`. Directions: `higher_is_worse`, `lower_is_worse`.
- `Scoring::TimeDecay.weight(age_days:, half_life_days:)` — exponential half-life decay `0.5 ^ (age_days / half_life_days)`. `apply(value:, age_days:, half_life_days:)` multiplies a contribution by the decay weight.

## Files

- `lib/scoring/signal_scalers.rb` — 5 scalers + clamp helper + direction validator
- `lib/scoring/time_decay.rb` — weight + apply
- `test/lib/scoring/signal_scalers_test.rb` — 22 tests covering every value_type × direction × edge case
- `test/lib/scoring/time_decay_test.rb` — half-life, clamp, ArgumentError paths

## Contract

### SignalScalers

- **Input validation raises, out-of-range values clamp.** Unknown `value_type` or `direction` → `ArgumentError`. Missing `min_value` / `max_value` for range-based types (`count`, `duration_seconds`, `money_cents`) → `ArgumentError`. But a `rate` of 1.7 or a `count` of 99_999 silently clamps to the `[min, max]` range. This split matters: invalid configuration is a programmer error; invalid data is a routine event the ingestion validator logs as an advisory.
- **Direction flips the output.** A `rate` of 0.10 under `higher_is_worse` → 10.0 (low risk); the same value under `lower_is_worse` → 90.0. Always pass `direction` from the `signal_definitions` row — never hardcode it in the caller.
- **Boolean scaling is ternary-safe.** Only `value == true` counts as "true"; `nil` or `"true"` (string) are treated as false. Callers coerce earlier if they need string parsing.

### TimeDecay

- **`half_life_days` must be positive.** Zero or negative → `ArgumentError`. The scoring_rules `time_decay_half_life_days` column has a DB `> 0` CHECK, so this rarely trips in practice — but library users who pass `0` get a clean error instead of `Infinity`.
- **Negative `age_days` clamps to 0 (weight = 1.0).** Future-dated signals should not exist (ingestion validator rejects them), but if one slips through, the decay weight is a safe 1.0 rather than an exploding `0.5 ** (-N)`.
- **`apply` is `value * weight`.** No magic; the caller is still responsible for checking whether applying decay makes sense (e.g. boolean signals are NOT time-decayed in most category aggregations — the composite scorer decides this, not `TimeDecay`).

## When to read this

Before:
- Writing `lib/scoring/composite_scorer.rb` (future batch) — it composes these two primitives
- Adding a new `value_type` to `signal_definitions` — the new type must round-trip through `SignalScalers.scale` or have its own code path
- Changing the scoring algorithm in any batch — these primitives are the atomic units; if you think you need to edit them, consider adding a new primitive alongside instead

## Cross-references

- Related modules: `lib/scoring/composite_scorer.rb` (future), `lib/ingestion/signal_validator.rb` (future)
- Related data: `signal_definitions.value_type` + `.direction` (PRD §4.4); `scoring_rules.time_decay_half_life_days` (PRD §4.7); `scoring_rules.window_days` (sets the age horizon)
- PRD: §5.4 Composite Scorer, §4.6 `vendor_scores` (composite_score column), §14 `DEFAULT_TIME_DECAY_HALF_LIFE_DAYS=45`
- Invariants: #4 Explainability (every contribution goes through `SignalScalers.scale` once, so `top_contributors` has a stable provenance); #6 Rules-driven, not ML (no learned weights; every knob is declarative)
