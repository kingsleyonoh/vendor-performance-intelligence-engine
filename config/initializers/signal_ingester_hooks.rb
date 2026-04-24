# frozen_string_literal: true

# Wire the signal ingester's post-insert hook to enqueue a
# `ScoreRecomputeJob` for the vendor that just got a fresh signal.
#
# This is the canonical wiring for PRD §5.3 step 6: every ingested
# signal triggers an asynchronous recompute. The core engine works
# standalone (Invariant 2) because the ingester defaults the hook to
# a no-op — this initializer swaps in the real one once the app is booted.
Rails.application.config.after_initialize do
  ::Ingestion::SignalIngester.post_insert_hook = lambda do |signal|
    next if signal.nil?

    ScoreRecomputeJob.perform_later(signal.vendor_id, signal.tenant_id)
  rescue StandardError => e
    # The hook must never surface back into the ingester (it would roll
    # back the signal insert — which violates append-only). Log and swallow.
    Rails.logger.error(
      "[signal_ingester_hooks] ScoreRecomputeJob enqueue failed: #{e.class}: #{e.message}"
    )
  end
end
