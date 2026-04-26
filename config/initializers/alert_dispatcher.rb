# frozen_string_literal: true

# Wires `ScoreRecomputeJob.band_crossing_hook` to `Alerts::Dispatcher`
# (PRD §5, §7, §13.2). After every score recompute, if the band crossed,
# the dispatcher captures a frozen DeliveryPayload, inserts a risk_alert,
# and enqueues HubDispatchJob.
#
# This is loaded after the application boots so all autoload-paths are
# ready. The Phase 1 default hook is a no-op — Phase 2 swaps it in here.

require_relative "../../lib/alerts/dispatcher"
require_relative "../../lib/alerts/capture_payload"

Rails.application.config.after_initialize do
  ScoreRecomputeJob.band_crossing_hook = lambda do |score, previous_band|
    Alerts::Dispatcher.on_band_crossing(score: score, previous_band: previous_band)
  end
end
