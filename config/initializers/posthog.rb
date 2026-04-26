# frozen_string_literal: true

# PostHog initializer — PRD §10b, §14.
#
# This initializer's only job is to require the facade so it loads at boot
# (Zeitwerk would also handle this, but explicit requires make the
# dependency relationship visible). The facade `Analytics::Event` no-ops
# when POSTHOG_API_KEY / POSTHOG_HOST is unset — see `lib/analytics/event.rb`
# for the contract.
require Rails.root.join("lib", "analytics", "event")
