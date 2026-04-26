# frozen_string_literal: true

# Performance benchmark — PRD §15 #2, §13.3.
#
# Validates: `POST /api/signals` followed by `GET /api/vendors/:id/score/current`
# round-trips in under 500ms p95 for a vendor with 500 in-window signals.
#
# Methodology:
#   1. Pre-seed a tenant + a target vendor + 500 in-window signals so the
#      scorer must aggregate over 500 rows on every recompute.
#   2. Boot Puma with `E2E_INLINE_JOBS=true` so ScoreRecomputeJob runs
#      synchronously inside the POST request — the user-perceived latency
#      includes the rescore.
#   3. For each iteration: POST a fresh signal (unique source_event_id),
#      then immediately GET /score/current — measure both legs and the
#      total roundtrip.
#   4. Compute p50/p95/p99/max across the configured iteration count.
#   5. Assert p95 roundtrip < 500ms.
#
# Run: `bin/dc bin/rake perf:bench:roundtrip`
# Iterations override: `PERF_ITERATIONS=200 bin/dc bin/rake perf:bench:roundtrip`

require_relative "perf_helper"

class SignalScoreRoundtripBench
  PORT = ENV.fetch("PERF_PORT", "3101").to_i
  ITERATIONS = ENV.fetch("PERF_ITERATIONS", "100").to_i
  PRESEED_SIGNALS = ENV.fetch("PERF_PRESEED_SIGNALS", "500").to_i
  P95_TARGET_MS = ENV.fetch("PERF_P95_TARGET_MS", "500").to_i

  SIGNAL_CODE = "invoice.late_ratio_30d"

  def run
    puts "=" * 78
    puts "Perf Benchmark: signal-ingest -> score-read roundtrip (PRD §15 #2)"
    puts "  iterations=#{ITERATIONS}  preseed=#{PRESEED_SIGNALS}  target=p95<#{P95_TARGET_MS}ms"
    puts "=" * 78

    PerfHelper.purge_test_db!
    PerfHelper.seed_signal_definitions!
    tenant, raw_key = PerfHelper.seed_tenant!(slug: "perf-roundtrip", display_name: "PerfRoundtrip")
    vendor = preseed_vendor_and_signals!(tenant)

    puts "[seed] tenant=#{tenant.id} vendor=#{vendor.id} signals=#{PRESEED_SIGNALS}"
    puts "[boot] starting Puma on port #{PORT}…"

    headers = { "X-API-Key" => raw_key }
    base = "http://127.0.0.1:#{PORT}"

    post_latencies = []
    get_latencies = []
    total_latencies = []
    errors = 0

    PerfHelper.boot_puma(port: PORT, extra_env: { "E2E_INLINE_JOBS" => "true" }) do
      # Warm-up: 3 untimed roundtrips so JIT / connection pooling /
      # Rails autoload don't pollute the first measurements.
      3.times { |i| roundtrip(base, headers, vendor.id, "warmup-#{i}") }

      ITERATIONS.times do |i|
        evt = "perf-rt-#{Process.pid}-#{i}-#{SecureRandom.hex(4)}"
        result = roundtrip(base, headers, vendor.id, evt)
        if result[:ok]
          post_latencies << result[:post_ms]
          get_latencies  << result[:get_ms]
          total_latencies << result[:total_ms]
        else
          errors += 1
          warn "[error iter=#{i}] post=#{result[:post_status]} get=#{result[:get_status]}"
        end
      end
    end

    print_results(post_latencies, get_latencies, total_latencies, errors)
    p95_total = PerfHelper.percentile_stats(total_latencies)[:p95]

    if p95_total > P95_TARGET_MS
      warn "FAIL: p95 roundtrip #{format('%.2f', p95_total)}ms exceeds target #{P95_TARGET_MS}ms"
      exit(1)
    else
      puts "PASS: p95 roundtrip #{format('%.2f', p95_total)}ms within target #{P95_TARGET_MS}ms"
    end
  end

  private

  def preseed_vendor_and_signals!(tenant)
    vendor = Vendor.create!(
      tenant_id: tenant.id,
      canonical_name: "Perf Roundtrip Supplier",
      tax_id: "PERF-RT-#{SecureRandom.hex(4)}",
      country_code: "GB",
      status: "active"
    )

    sig_def = SignalDefinition.find_by!(code: SIGNAL_CODE)
    PerfHelper.bulk_insert_signals!(
      tenant_id: tenant.id,
      vendor_id: vendor.id,
      signal_code: SIGNAL_CODE,
      signal_definition_id: sig_def.id,
      value_type: sig_def.value_type,
      count: PRESEED_SIGNALS,
      value_proc: ->(i) { 0.05 + (i % 20) * 0.01 },
      age_seconds_proc: ->(i) { i * 60 },
      tag: "perf-preseed"
    )
    vendor
  end

  def roundtrip(base, headers, vendor_id, source_event_id)
    payload = {
      vendor_ref: {
        normalized_name: "perf roundtrip supplier",
        tax_id: nil
      },
      signal_code: SIGNAL_CODE,
      source_system: "invoice_recon",
      source_event_id: source_event_id,
      value_numeric: 0.10,
      recorded_at: Time.now.utc.iso8601
    }
    # Send the POST against the SAME vendor by passing its tax_id so the
    # resolver's tax_id rung matches.
    payload[:vendor_ref][:tax_id] = Vendor.find(vendor_id).tax_id

    post_uri = URI.join(base, "/api/signals")
    score_uri = URI.join(base, "/api/vendors/#{vendor_id}/score/current")

    t0 = monotonic_ms
    post_res = PerfHelper.post_json(post_uri, payload, headers: headers)
    t1 = monotonic_ms
    get_res = PerfHelper.get(score_uri, headers: headers)
    t2 = monotonic_ms

    {
      ok: post_res.code == "201" && get_res.code == "200",
      post_status: post_res.code,
      get_status: get_res.code,
      post_ms: t1 - t0,
      get_ms: t2 - t1,
      total_ms: t2 - t0
    }
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  end

  def print_results(post_lat, get_lat, total_lat, errors)
    puts ""
    puts "Results:"
    puts "  errors=#{errors}/#{ITERATIONS}"
    puts "  " + PerfHelper.format_stats("POST /signals", PerfHelper.percentile_stats(post_lat))
    puts "  " + PerfHelper.format_stats("GET  /score",   PerfHelper.percentile_stats(get_lat))
    puts "  " + PerfHelper.format_stats("ROUNDTRIP",     PerfHelper.percentile_stats(total_lat))
    puts ""
  end
end

if __FILE__ == $PROGRAM_NAME
  SignalScoreRoundtripBench.new.run
end
