# frozen_string_literal: true

module Reports
  # Builds the FROZEN RenderContext Hash stored on
  # `vendor_reports.render_context` at the queued → generating
  # transition (PRD §5.6). Every subsequent re-render of the report
  # binds to the stored snapshot — the renderer NEVER re-queries
  # tenants/vendors/scores. This is what makes audit reprints
  # byte-identical 30 days after original generation, even if the
  # underlying tenant/vendor rows have been mutated in between
  # (PRD §15 #13).
  #
  # Mirror of `Alerts::CapturePayload` for the report surface. Both
  # bind to `Tenants::CaptureSnapshot` for the tenant identity block.
  #
  # The `data` block is type-aware. Each `report_type` has a private
  # capturer that loads the type-specific data (vendor + scores +
  # signals for vendor_scorecard, tenant-wide aggregates for
  # portfolio_risk, etc.). All data blocks are deep-frozen.
  #
  # See `.agent/knowledge/foundation/render-context-shape.md` for the
  # locked shape contract.
  class CaptureRenderContext
    SCHEMA_VERSION = "vpi.report.v1"
    DEEP_LINK_HOST = ENV.fetch("VPI_HOST_URL", "https://vendors.kingsleyonoh.com")
    SCORECARD_HISTORY_LIMIT = 12 # last 12 weekly score points
    SCORECARD_SIGNAL_TIMELINE_LIMIT = 50

    def self.call(vendor_report:)
      new.call(vendor_report: vendor_report)
    end

    def call(vendor_report:)
      raise ArgumentError, "vendor_report must be a VendorReport" unless vendor_report.is_a?(VendorReport)

      tenant_snapshot = Tenants::CaptureSnapshot.call(vendor_report.tenant_id)

      ctx = {
        schema_version: SCHEMA_VERSION,
        generated_at: Time.now.utc.iso8601,
        tenant: tenant_snapshot,
        report: report_block(vendor_report),
        data: data_block(vendor_report),
        links: links_block(vendor_report, tenant_snapshot)
      }

      deep_freeze(ctx)
    end

    private

    def report_block(report)
      {
        id: report.id,
        type: report.report_type,
        parameters: stringify_keys_shallow(report.parameters || {}),
        output_format: report.output_format,
        requested_by_user_id: report.requested_by_user_id,
        generated_at: report.generated_at&.utc&.iso8601,
        expires_at: report.expires_at&.utc&.iso8601
      }
    end

    def data_block(report)
      case report.report_type
      when "vendor_scorecard"
        capture_vendor_scorecard(report)
      when "portfolio_risk"
        capture_portfolio_risk(report)
      when "retender_candidates"
        capture_retender_candidates(report)
      when "trend_analysis"
        capture_trend_analysis(report)
      else
        {}
      end
    end

    def capture_vendor_scorecard(report)
      vendor = report.vendor
      raise ArgumentError, "vendor_scorecard report requires a vendor_id" if vendor.nil?

      latest = VendorScore.where(tenant_id: report.tenant_id, vendor_id: vendor.id)
                          .order(computed_at: :desc).first
      history = VendorScore.where(tenant_id: report.tenant_id, vendor_id: vendor.id)
                           .order(computed_at: :desc).limit(SCORECARD_HISTORY_LIMIT)
      signals = VendorSignal.where(tenant_id: report.tenant_id, vendor_id: vendor.id, status: %w[normalized scored])
                            .order(recorded_at: :desc).limit(SCORECARD_SIGNAL_TIMELINE_LIMIT)
      aliases = VendorAlias.where(tenant_id: report.tenant_id, vendor_id: vendor.id)

      {
        vendor: vendor_block(vendor),
        latest_score: latest ? score_block(latest) : nil,
        score_history: history.map { |s| score_block(s) },
        signal_timeline: signals.map { |s| signal_block(s) },
        aliases: aliases.map { |a| alias_block(a) }
      }
    end

    def capture_portfolio_risk(report)
      scope = VendorScore.where(tenant_id: report.tenant_id)
      latest_per_vendor_ids = scope.select("DISTINCT ON (vendor_id) id")
                                   .order(:vendor_id, computed_at: :desc)
                                   .map(&:id)
      latest = VendorScore.where(id: latest_per_vendor_ids)
      band_counts = latest.group(:band).count

      {
        vendor_count: latest.count,
        band_counts: band_counts.transform_keys(&:to_s),
        vendors: latest.includes(:vendor).map { |s|
          { vendor_id: s.vendor_id, canonical_name: s.vendor.canonical_name,
            band: s.band, composite_score: s.composite_score.to_f }
        }
      }
    end

    def capture_retender_candidates(report)
      scope = VendorScore.where(tenant_id: report.tenant_id, band: %w[high critical])
      latest_per_vendor_ids = scope.select("DISTINCT ON (vendor_id) id")
                                   .order(:vendor_id, computed_at: :desc)
                                   .map(&:id)
      latest = VendorScore.where(id: latest_per_vendor_ids).includes(:vendor)

      {
        candidates: latest.map { |s|
          { vendor_id: s.vendor_id, canonical_name: s.vendor.canonical_name,
            band: s.band, composite_score: s.composite_score.to_f,
            top_contributors: Array(s.top_contributors).first(5) }
        }
      }
    end

    def capture_trend_analysis(report)
      window = (report.parameters && (report.parameters["window_days"] || report.parameters[:window_days])) || 90
      since = window.to_i.days.ago

      scores = VendorScore.where(tenant_id: report.tenant_id)
                          .where("computed_at >= ?", since)
                          .order(computed_at: :asc)

      buckets = scores.group_by { |s| s.computed_at.to_date.beginning_of_week.iso8601 }
      weekly = buckets.map do |week_start, rows|
        {
          week_start: week_start,
          score_count: rows.size,
          avg_composite: (rows.sum { |r| r.composite_score.to_f } / rows.size.to_f).round(3),
          band_counts: rows.group_by(&:band).transform_values(&:size)
        }
      end

      { weekly_buckets: weekly, window_days: window.to_i }
    end

    def vendor_block(vendor)
      {
        id: vendor.id,
        canonical_name: vendor.canonical_name,
        category: vendor.category,
        country_code: vendor.country_code,
        annual_spend_cents: vendor.annual_spend_cents.to_i,
        currency: vendor.currency,
        status: vendor.status
      }
    end

    def score_block(score)
      {
        id: score.id,
        composite_score: score.composite_score.to_f,
        band: score.band,
        trend: score.trend,
        category_scores: stringify_keys_shallow(score.category_scores || {}),
        top_contributors: Array(score.top_contributors).first(5),
        window_days: score.window_days,
        computed_at: score.computed_at.utc.iso8601
      }
    end

    def signal_block(signal)
      {
        signal_code: signal.signal_code,
        source_system: signal.source_system,
        value_numeric: signal.value_numeric&.to_f,
        value_boolean: signal.value_boolean,
        recorded_at: signal.recorded_at.utc.iso8601
      }
    end

    def alias_block(alias_row)
      {
        id: alias_row.id,
        source_system: alias_row.source_system,
        source_ref: alias_row.source_ref,
        confidence: alias_row.confidence&.to_f
      }
    end

    def links_block(report, tenant_snapshot)
      {
        download_url: "#{DEEP_LINK_HOST}/api/reports/#{report.id}/download",
        view_url: "#{DEEP_LINK_HOST}/reports/#{report.id}",
        legal_footer: {
          full_legal_name: tenant_snapshot[:full_legal_name],
          address: tenant_snapshot[:address],
          registration: tenant_snapshot[:registration],
          contact: tenant_snapshot[:contact]
        }
      }
    end

    def stringify_keys_shallow(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end

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
