# frozen_string_literal: true

# Performance benchmark — PRD §15 #8, §13.3.
#
# Validates: each of the three report types (`vendor_scorecard` PDF,
# `portfolio_risk` CSV+PDF, `retender_candidates` CSV) generates within
# 30 seconds for a tenant with 100+ vendors.
#
# Methodology:
#   1. Pre-seed ONE tenant with 120 vendors (mix of bands), ~30 signals
#      per vendor, and 3 latest scores per vendor — that's the realistic
#      shape of a procurement portfolio at v1 scale.
#   2. Boot Puma with `E2E_INLINE_JOBS=true` so ReportGeneratorJob runs
#      synchronously inside the POST /api/reports request — wall clock
#      from POST → 201 covers full generation.
#   3. For each report type: POST to /api/reports, measure wall-clock
#      duration until the response returns + the report is in `ready`.
#   4. Run sequentially (parallel would distort wall-clock timings under
#      shared CPU + DB pool contention).
#   5. Assert each report type completes in under 30s.
#
# Run: `bin/dc bin/rake perf:bench:reports`

require_relative "perf_helper"

class ReportGenerationBench
  PORT = ENV.fetch("PERF_PORT", "3103").to_i
  VENDOR_COUNT = ENV.fetch("PERF_VENDOR_COUNT", "120").to_i
  SIGNALS_PER_VENDOR = ENV.fetch("PERF_SIGNALS_PER_VENDOR", "30").to_i
  TARGET_MS = ENV.fetch("PERF_TARGET_MS", "30000").to_i

  REPORT_SPECS = [
    {
      type: "vendor_scorecard",
      output_format: "pdf",
      params_proc: ->(v) { { vendor_id: v.id, period: "30d" } }
    },
    {
      type: "portfolio_risk",
      output_format: "csv",
      params_proc: ->(_v) { { period: "30d" } }
    },
    {
      type: "retender_candidates",
      output_format: "csv",
      params_proc: ->(_v) { { period: "30d" } }
    }
  ].freeze

  def run
    puts "=" * 78
    puts "Perf Benchmark: report generation (PRD §15 #8)"
    puts "  vendors=#{VENDOR_COUNT}  signals/vendor=#{SIGNALS_PER_VENDOR}  target=<#{TARGET_MS}ms each"
    puts "=" * 78

    PerfHelper.purge_test_db!
    PerfHelper.seed_signal_definitions!
    tenant, raw_key = PerfHelper.seed_tenant!(slug: "perf-reports", display_name: "PerfReports")

    sample_vendor = preseed_portfolio!(tenant)
    puts "[seed] tenant=#{tenant.id} vendors=#{VENDOR_COUNT} sample_vendor=#{sample_vendor.id}"
    puts "[boot] starting Puma on port #{PORT}…"

    headers = { "X-API-Key" => raw_key, "Content-Type" => "application/json" }
    base = "http://127.0.0.1:#{PORT}"

    durations = {}
    errors = []

    PerfHelper.boot_puma(port: PORT, extra_env: { "E2E_INLINE_JOBS" => "true" }) do
      REPORT_SPECS.each do |spec|
        spec_label = "#{spec[:type]}.#{spec[:output_format]}"
        body = {
          report_type: spec[:type],
          output_format: spec[:output_format],
          parameters: spec[:params_proc].call(sample_vendor)
        }
        t0 = monotonic_ms
        res = PerfHelper.post_json(URI.join(base, "/api/reports"), body, headers: headers)
        t1 = monotonic_ms

        if res.code != "202"
          errors << "#{spec_label}: status=#{res.code} body=#{res.body[0, 200]}"
          next
        end

        report_id = JSON.parse(res.body).dig("report", "id")
        # POST returned 202 — but with E2E_INLINE_JOBS the job already ran
        # synchronously (perform_later is inline-flushed before the
        # controller returns), so the report should already be `ready`.
        # GET to confirm and surface any error_summary.
        status_res = PerfHelper.get(URI.join(base, "/api/reports/#{report_id}"), headers: headers)
        parsed = JSON.parse(status_res.body) rescue {}
        report_status = parsed.dig("report", "status") || parsed["status"]

        if report_status != "ready"
          errors << "#{spec_label}: report status=#{report_status} (expected ready)"
        end

        durations[spec_label] = t1 - t0
      end
    end

    print_results(durations, errors)

    failures = durations.select { |_label, ms| ms > TARGET_MS }
    if errors.any?
      warn "ERRORS:"
      errors.each { |e| warn "  - #{e}" }
      exit(1)
    end
    if failures.any?
      warn "FAIL: report generation exceeded target:"
      failures.each { |label, ms| warn "  #{label}: #{format('%.2f', ms)}ms > #{TARGET_MS}ms" }
      exit(1)
    end
    puts "PASS: every report type generated within #{TARGET_MS}ms"
  end

  private

  def preseed_portfolio!(tenant)
    sig_def = SignalDefinition.find_by!(code: "invoice.late_ratio_30d")
    rule_id = ScoringRule.where(tenant_id: tenant.id, is_active: true).pick(:id)
    bands = %w[low medium high critical]
    now = Time.now.utc
    sample = nil

    VENDOR_COUNT.times do |i|
      v = Vendor.create!(
        tenant_id: tenant.id,
        canonical_name: "Perf Vendor #{i}",
        tax_id: "PERF-V-#{SecureRandom.hex(4)}",
        country_code: "GB",
        status: "active",
        annual_spend_cents: (100_000 + i * 5000) * 100,
        currency: "EUR"
      )
      sample ||= v

      PerfHelper.bulk_insert_signals!(
        tenant_id: tenant.id,
        vendor_id: v.id,
        signal_code: "invoice.late_ratio_30d",
        signal_definition_id: sig_def.id,
        value_type: sig_def.value_type,
        count: SIGNALS_PER_VENDOR,
        value_proc: ->(s) { 0.05 + (s % 10) * 0.04 },
        age_seconds_proc: ->(s) { s * 3_600 },
        tag: "perf-rep-#{i}"
      )

      band = bands[i % bands.size]
      score_value = case band
                    when "low" then 15.0
                    when "medium" then 45.0
                    when "high" then 70.0
                    when "critical" then 90.0
                    end
      3.times do |k|
        VendorScore.create!(
          tenant_id: tenant.id,
          vendor_id: v.id,
          composite_score: score_value,
          band: band,
          trend: "stable",
          category_scores: {
            "financial" => score_value, "operational" => 0.0, "contractual" => 0.0,
            "integration" => 0.0, "transactional" => 0.0
          },
          top_contributors: [],
          window_days: 90,
          scoring_rules_id: rule_id,
          computed_at: now - (k * 86_400)
        )
      end
    end
    sample
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  end

  def print_results(durations, errors)
    puts ""
    puts "Results:"
    durations.each do |label, ms|
      flag = ms > TARGET_MS ? "[OVER]" : "[ OK ]"
      puts "  #{flag} #{label.ljust(28)} #{format('%.2f', ms)}ms"
    end
    if errors.any?
      puts "  errors=#{errors.size}"
    end
    puts ""
  end
end

if __FILE__ == $PROGRAM_NAME
  ReportGenerationBench.new.run
end
