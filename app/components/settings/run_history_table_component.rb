# frozen_string_literal: true

module Settings
  # Tabular display of recent ingestion runs for one source.
  class RunHistoryTableComponent < ViewComponent::Base
    def initialize(runs:)
      @runs = runs
    end

    attr_reader :runs

    def status_color(status)
      case status
      when "succeeded" then "#C6F6D5"
      when "failed"    then "#FED7D7"
      when "running"   then "#BEE3F8"
      when "partial"   then "#FEEBC8"
      else "#E2E8F0"
      end
    end

    def status_text_color(status)
      case status
      when "succeeded" then "#22543D"
      when "failed"    then "#742A2A"
      when "running"   then "#2A4365"
      when "partial"   then "#7B341E"
      else "#4A5568"
      end
    end
  end
end
