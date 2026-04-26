# frozen_string_literal: true

module Scoring
  # Scoring::RulePreviewer — PRD §15 #7. Dry-runs a candidate scoring_rule
  # against a sample of vendors and returns band-change deltas. NEVER
  # persists a `vendor_scores` row — every call uses
  # `Scoring::CompositeScorer.call(persist: false)`.
  #
  # Extracted from `Api::ScoringRulesController#preview` so the controller
  # stays a thin dispatcher (parse params → call → render). Pure tenant-
  # scoped read; no mutations.
  class RulePreviewer
    SAMPLE_SIZE = 10

    # @param tenant [Tenant]
    # @param scoring_rule [ScoringRule] the candidate rule (may be is_active=false)
    # @param vendor_ids [Array<String>] explicit vendor UUIDs to preview;
    #        when empty, picks up to SAMPLE_SIZE highest-scored vendors,
    #        backfilled by most-recently-created.
    # @return [Hash] { previews: [...], summary: { total_previewed:, changed_count:, rule_id: } }
    def self.call(tenant:, scoring_rule:, vendor_ids: [])
      new(tenant: tenant, scoring_rule: scoring_rule, vendor_ids: vendor_ids).call
    end

    def initialize(tenant:, scoring_rule:, vendor_ids: [])
      @tenant = tenant
      @scoring_rule = scoring_rule
      @vendor_ids = Array(vendor_ids).select { |id| id.is_a?(String) }
    end

    def call
      vendors = resolve_vendors
      previews = vendors.map { |v| preview_for_vendor(v) }.compact
      changed = previews.count { |p| %w[improving degrading crossed_up crossed_down].include?(p[:band_change].to_s) }

      {
        previews: previews,
        summary: {
          total_previewed: previews.size,
          changed_count: changed,
          rule_id: @scoring_rule.id
        }
      }
    end

    private

    def resolve_vendors
      if @vendor_ids.any?
        Vendor.where(tenant_id: @tenant.id, id: @vendor_ids).to_a
      else
        sample_for_preview
      end
    end

    # Sample picker: top-scored vendors first, backfill with most-recent.
    def sample_for_preview
      ranked_ids = VendorScore
                     .where(tenant_id: @tenant.id)
                     .select("DISTINCT ON (vendor_id) vendor_id, composite_score")
                     .order("vendor_id, computed_at DESC")
                     .map(&:vendor_id)

      scored = VendorScore
                 .where(tenant_id: @tenant.id, vendor_id: ranked_ids)
                 .order(composite_score: :desc)
                 .pluck(:vendor_id).uniq.first(SAMPLE_SIZE)

      vendors = Vendor.where(tenant_id: @tenant.id, id: scored).to_a
      return vendors if vendors.size >= SAMPLE_SIZE

      needed = SAMPLE_SIZE - vendors.size
      existing_ids = vendors.map(&:id)
      backfill = Vendor.where(tenant_id: @tenant.id)
                       .where.not(id: existing_ids)
                       .order(created_at: :desc)
                       .limit(needed)
                       .to_a
      vendors + backfill
    end

    def preview_for_vendor(vendor)
      current = VendorScore.where(tenant_id: @tenant.id, vendor_id: vendor.id)
                           .order(computed_at: :desc).first

      result = ::Scoring::CompositeScorer.call(
        vendor_id: vendor.id, tenant: @tenant,
        scoring_rule: @scoring_rule, persist: false
      )
      return nil if result.nil?

      new_band = result[:band]
      new_composite = result[:composite_score]
      current_band = current&.band
      current_composite = current&.composite_score&.to_f
      {
        vendor_id: vendor.id,
        vendor_name: vendor.canonical_name,
        current_band: current_band,
        new_band: new_band,
        current_composite: current_composite,
        new_composite: new_composite,
        band_change: classify_band_change(current_band, new_band, current_composite, new_composite)
      }
    end

    def classify_band_change(current_band, new_band, current_composite, new_composite)
      return "new" if current_band.nil?
      return "stable" if current_band == new_band && (current_composite.to_f - new_composite.to_f).abs < 5

      current_idx = VendorScore::BANDS.index(current_band.to_s)
      new_idx = VendorScore::BANDS.index(new_band.to_s)
      return "stable" if current_idx.nil? || new_idx.nil? || current_idx == new_idx

      new_idx > current_idx ? "crossed_up" : "crossed_down"
    end
  end
end
