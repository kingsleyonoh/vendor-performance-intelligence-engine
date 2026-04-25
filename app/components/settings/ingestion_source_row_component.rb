# frozen_string_literal: true

module Settings
  # Single row in the Settings → Ingestion Sources table.
  class IngestionSourceRowComponent < ViewComponent::Base
    def initialize(source:)
      @source = source
    end

    attr_reader :source

    def status_label
      return "disabled" unless source.is_enabled
      return "never pulled" if source.last_successful_pull.nil?

      hours = ((Time.now.utc - source.last_successful_pull) / 3600.0).round(1)
      hours > 24 ? "stale (#{hours}h)" : "healthy"
    end

    def status_color
      case status_label
      when /stale/    then "#FED7D7"
      when "disabled" then "#E2E8F0"
      when /never/    then "#FEEBC8"
      else "#C6F6D5"
      end
    end

    def status_text_color
      case status_label
      when /stale/    then "#742A2A"
      when "disabled" then "#4A5568"
      when /never/    then "#7B341E"
      else "#22543D"
      end
    end

    def last_pull_label
      source.last_successful_pull&.strftime("%Y-%m-%d %H:%M UTC") || "—"
    end
  end
end
