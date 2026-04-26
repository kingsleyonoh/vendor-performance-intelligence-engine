# frozen_string_literal: true

require "csv"

module Reports
  # Re-tender candidates CSV (PRD §5, §13.3). Lists HIGH and CRITICAL
  # band vendors with a derived recommended_action.
  #
  # Recommended-action thresholds (composite_score):
  #   < 30   → "RFQ immediately"
  #   30..49 → "Monitor 30d then RFQ"
  #   ≥ 50   → "Watchlist"
  #
  # Note: lower composite_score == lower-risk in VPI's scoring scale.
  # Re-tender candidates are HIGH/CRITICAL banded; within those, a LOWER
  # composite_score paradoxically does NOT happen (high band ≥ band
  # threshold). The thresholds above are scored against the captured
  # composite_score values verbatim — operators reading the CSV want a
  # one-glance action label per row regardless of band semantics.
  class RetenderCandidatesGenerator < BaseGenerator
    HEADERS = %w[
      vendor_id canonical_name band composite_score
      annual_spend top_3_signal_codes recommended_action
    ].freeze

    protected

    def render
      candidates = f("data.candidates")
      _          = f("tenant.legal_name") # tenant token must resolve

      bytes = CSV.generate do |csv|
        csv << HEADERS
        Array(candidates).each do |c|
          csv << row_for(c)
        end
      end

      { bytes: bytes, extension: "csv", inline: true }
    end

    private

    def row_for(candidate)
      score = candidate["composite_score"].to_f
      contributors = Array(candidate["top_contributors"]).first(3).map { |row|
        row["signal_code"] || row[:signal_code]
      }.compact

      [
        candidate["vendor_id"],
        candidate["canonical_name"],
        candidate["band"],
        format("%.2f", score),
        candidate["annual_spend_cents"] || "",
        contributors.join(";"),
        recommended_action_for(score)
      ]
    end

    def recommended_action_for(score)
      if score < 30
        "RFQ immediately"
      elsif score < 50
        "Monitor 30d then RFQ"
      else
        "Watchlist"
      end
    end
  end
end
