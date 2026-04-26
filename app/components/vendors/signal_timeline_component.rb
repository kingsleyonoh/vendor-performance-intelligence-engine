# frozen_string_literal: true

# Vendors::SignalTimelineComponent — list of the last ≤20 vendor_signals,
# newest first. Source-event ref is shown as plain text (Phase 1);
# deep-link URLs come in Phase 2 once per-source adapter URLs are configured.
module Vendors
  class SignalTimelineComponent < ViewComponent::Base
    def initialize(signals:)
      @signals = Array(signals)
    end

    attr_reader :signals

    def empty?
      signals.empty?
    end

    def relative_time(ts)
      return "—" unless ts
      seconds = Time.now.utc - ts.to_time.utc
      if seconds < 60
        "just now"
      elsif seconds < 3600
        "#{(seconds / 60).to_i}m ago"
      elsif seconds < 86_400
        "#{(seconds / 3600).to_i}h ago"
      else
        "#{(seconds / 86_400).to_i}d ago"
      end
    end

    def display_value(signal)
      return signal.value_numeric.to_s if signal.value_numeric.present?
      return signal.value_boolean.to_s unless signal.value_boolean.nil?
      "—"
    end
  end
end
