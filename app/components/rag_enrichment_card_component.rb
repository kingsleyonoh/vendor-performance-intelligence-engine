# frozen_string_literal: true

# RagEnrichmentCardComponent — PRD §5.7, §8, §13.3.
#
# Renders the "Background & Relationships" card on the Vendor Detail
# page. Reads from `vendor.metadata['rag_enrichment']` produced by
# `RagEnrichmentJob`. Hides itself entirely when:
#   - `RAG_PLATFORM_ENABLED != "true"` (feature off — no card), OR
#   - `vendor.metadata['rag_enrichment']` is nil (never enriched — no card)
#
# When enrichment ran but RAG returned zero entities, renders an empty
# state inside the card so operators can tell the difference between
# "we have not asked yet" and "we asked, found nothing."
class RagEnrichmentCardComponent < ViewComponent::Base
  def initialize(vendor:)
    @vendor = vendor
  end

  attr_reader :vendor

  # Decide whether to render the card at all. Returns false when the
  # feature flag is off or no enrichment data is present — the helper is
  # used by the view's `<% if visible? %>` guard so the entire <section>
  # is suppressed (no empty wrapper leaks into the DOM).
  def render?
    feature_enabled? && enrichment_present?
  end

  def entities
    Array((enrichment_data["entities"] || []))
  end

  def empty?
    entities.empty?
  end

  def fetched_at
    raw = enrichment_data["fetched_at"]
    return nil if raw.blank?

    Time.iso8601(raw.to_s).utc
  rescue ArgumentError
    nil
  end

  private

  def feature_enabled?
    ENV.fetch("RAG_PLATFORM_ENABLED", "false").to_s.downcase == "true"
  end

  def enrichment_present?
    !enrichment_data.empty?
  end

  def enrichment_data
    metadata = vendor&.metadata
    return {} unless metadata.is_a?(Hash)

    raw = metadata["rag_enrichment"]
    raw.is_a?(Hash) ? raw : {}
  end
end
