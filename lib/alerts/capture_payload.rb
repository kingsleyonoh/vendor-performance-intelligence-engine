# frozen_string_literal: true

module Alerts
  # Builds the FROZEN DeliveryPayload Hash that is stored in
  # `risk_alerts.delivery_payload` at alert creation (PRD §5.5). The Hub
  # dispatcher reads ONLY from the stored column — never re-queries
  # tenants/vendors/vendor_scores. This is what makes alert history
  # legally defensible: a tenant rename or vendor merge between alert
  # creation and dispatch retry MUST NOT change the emitted Hub event.
  #
  # The result is recursively (deep-)frozen so the Sidekiq job that
  # reads it later cannot accidentally mutate the snapshot in memory
  # before serializing.
  class CapturePayload
    DEEP_LINK_HOST = ENV.fetch("VPI_HOST_URL", "https://vendors.kingsleyonoh.com")

    def self.call(vendor_score:)
      new.call(vendor_score: vendor_score)
    end

    def call(vendor_score:)
      raise ArgumentError, "vendor_score must be a VendorScore" unless vendor_score.is_a?(VendorScore)

      tenant = vendor_score.tenant
      vendor = vendor_score.vendor
      tenant_snapshot = Tenants::CaptureSnapshot.call(tenant.id)

      previous_score = previous_score_for(vendor_score)
      previous_band = previous_score&.band || vendor_score.band
      previous_composite = previous_score&.composite_score&.to_f || vendor_score.composite_score.to_f

      direction = vendor_score.band == previous_band ? nil : compute_direction(previous_band, vendor_score.band)
      event_type = direction == "improvement" ? "vendor.risk_band_improved" : "vendor.risk_band_changed"

      payload = {
        event_type: event_type,
        event_id: nil, # populated by alert router post-insert (vpi-<alert_uuid>)
        alert_id: nil, # populated post-insert
        tenant: tenant_snapshot,
        vendor: vendor_block(vendor, tenant_snapshot),
        score: score_block(vendor_score, previous_composite, previous_band, direction),
        top_contributors: top_contributors_block(vendor_score),
        deep_links: deep_links_block(vendor),
        created_at: Time.now.utc.iso8601
      }

      deep_freeze(payload)
    end

    private

    def previous_score_for(vendor_score)
      VendorScore
        .where(tenant_id: vendor_score.tenant_id, vendor_id: vendor_score.vendor_id)
        .where("computed_at < ?", vendor_score.computed_at)
        .order(computed_at: :desc)
        .limit(1)
        .first
    end

    def compute_direction(previous_band, new_band)
      band_rank = { "low" => 0, "medium" => 1, "high" => 2, "critical" => 3 }
      pr = band_rank[previous_band.to_s]
      nr = band_rank[new_band.to_s]
      return "escalation" if pr.nil? || nr.nil?

      nr > pr ? "escalation" : "improvement"
    end

    def vendor_block(vendor, tenant_snapshot)
      {
        id: vendor.id,
        canonical_name: vendor.canonical_name,
        category: vendor.category,
        country_code: vendor.country_code,
        annual_spend: annual_spend_block(vendor, tenant_snapshot),
        status: vendor.status
      }
    end

    def annual_spend_block(vendor, tenant_snapshot)
      cents = vendor.annual_spend_cents.to_i
      currency = vendor.currency.presence || "USD"
      {
        cents: cents,
        currency: currency,
        formatted: format_money(cents, currency, tenant_snapshot[:locale])
      }
    end

    # Cheap locale-aware formatting using Ruby's stdlib. Future Phase 3
    # work will swap in a richer formatter; this gets us deterministic
    # output for templates today.
    def format_money(cents, currency, locale)
      whole = cents / 100
      formatted_whole =
        if locale.to_s.start_with?("de-")
          whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse
        else
          whole.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
        end
      "#{formatted_whole} #{currency}"
    end

    def score_block(vendor_score, previous_composite, previous_band, direction)
      {
        previous: previous_composite.round(3),
        new: vendor_score.composite_score.to_f.round(3),
        previous_band: previous_band,
        new_band: vendor_score.band,
        direction: direction || "stable",
        trend: vendor_score.trend,
        window_days: vendor_score.window_days,
        category_scores: stringify_keys(vendor_score.category_scores || {}),
        computed_at: vendor_score.computed_at.utc.iso8601
      }
    end

    def top_contributors_block(vendor_score)
      Array(vendor_score.top_contributors).first(5).map do |c|
        c = c.transform_keys(&:to_s) if c.respond_to?(:transform_keys)
        {
          signal_code: c["signal_code"],
          category: c["category"],
          contribution_pct: c["contribution"] || c["contribution_pct"],
          value: c["value"],
          direction: c["direction"]
        }
      end
    end

    def deep_links_block(vendor)
      {
        vendor_detail: "#{DEEP_LINK_HOST}/vendors/#{vendor.id}",
        alert_detail: "#{DEEP_LINK_HOST}/alerts", # filled in post-insert with alert id
        acknowledge: "#{DEEP_LINK_HOST}/alerts/acknowledge"
      }
    end

    def stringify_keys(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v.is_a?(Hash) ? stringify_keys(v) : v }
    end

    # Recursively freeze every Hash and Array (and their string values)
    # so the captured snapshot cannot be mutated in flight.
    def deep_freeze(obj)
      case obj
      when Hash
        obj.each_value { |v| deep_freeze(v) }
        obj.freeze
      when Array
        obj.each { |v| deep_freeze(v) }
        obj.freeze
      when String
        obj.freeze
      else
        obj
      end
    end
  end
end
