# frozen_string_literal: true

module Alerts
  # Alerts::InboxRowComponent — single row in the alert inbox table.
  # Renders vendor link, band-change pill, status, timing, and lifecycle
  # actions (Acknowledge, Suppress, Retry) gated by the alert's status.
  class InboxRowComponent < ViewComponent::Base
    def initialize(alert:)
      @alert = alert
    end

    attr_reader :alert

    def vendor
      alert.vendor
    end

    def can_acknowledge?
      alert.acknowledged_at.blank? && %w[pending dispatching delivered failed].include?(alert.status)
    end

    def can_suppress?
      %w[pending dispatching delivered failed].include?(alert.status)
    end

    def can_retry?
      alert.status == "failed"
    end

    def relative_time
      diff_secs = Time.current - alert.created_at
      mins = (diff_secs / 60).to_i
      return "#{mins}m ago" if mins < 60

      hours = (mins / 60).to_i
      return "#{hours}h ago" if hours < 24

      "#{(hours / 24).to_i}d ago"
    end

    def dom_id
      "alert_#{alert.id}"
    end
  end
end
