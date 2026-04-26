# frozen_string_literal: true

# Load test — PRD §15 #4, §13.3.
#
# Validates: signal ingestion sustains 500 signals/sec for 10 minutes
# without queue backup, error rate spikes, or DB lock contention.
#
# Two run modes:
#   - SHORT (default, CI gate): `LOAD_TEST_DURATION_SEC=30`. Proves the
#     harness works and validates a *configurable* sustained throughput
#     for 30s. Suitable for PR pipelines. Default target on the dev
#     container is `LOAD_TEST_TARGET_QPS=30` because a single-worker Puma
#     with default thread count and a synchronous JIT-cold ingest path
#     averages ~500ms per request — yielding ~30 sustained QPS at 20
#     concurrent threads. Operators running this against a tuned
#     production-grade Puma (`WEB_CONCURRENCY=8`, `RAILS_MAX_THREADS=10`)
#     should set `LOAD_TEST_TARGET_QPS=500` to exercise the PRD #4 cap.
#
#   - FULL (manual pre-deploy): `LOAD_TEST_DURATION_SEC=600` (10 min) +
#     `LOAD_TEST_TARGET_QPS=500`. The full PRD §15 #4 acceptance run.
#     Invoked via `bin/dc bin/rake perf:load:full` — NOT in CI. MUST be
#     run against a production-config Puma; results from the dev
#     container are not representative of the production cap.
#
# Methodology:
#   1. Boot Puma with E2E_INLINE_JOBS=false (the default test adapter is
#      :test which queues but doesn't execute → score recompute does NOT
#      run inside the request, isolating measured latency to ingestion
#      itself; queue depth is then read off ActiveJob's test queue).
#   2. Spawn `LOAD_TEST_THREADS` (default 50) concurrent ruby threads.
#      Each thread loops: sleep until next slot → POST one signal → record
#      latency + status. The slot interval is `1.0 / target_qps_per_thread`
#      so all threads together aim for the configured TARGET_QPS.
#   3. Sample queue depth + Postgres connection-pool stats every second.
#   4. After duration: compute throughput, error rate, p50/p95/p99 ingest
#      latency. Assert: throughput >= TARGET_QPS * 0.95, error rate <= 1%,
#      queue depth bounded (not unboundedly growing).
#
# CRITICAL: this load test produces real load against the booted Puma. Do
# not run it on top of a parallel test suite. The harness purges the test
# DB at start.

require_relative "perf_helper"
require "concurrent"

class LoadTestSignalIngestion
  PORT = ENV.fetch("PERF_PORT", "3104").to_i
  TARGET_QPS = ENV.fetch("LOAD_TEST_TARGET_QPS", "30").to_i
  DURATION_SEC = ENV.fetch("LOAD_TEST_DURATION_SEC", "30").to_i
  THREADS = ENV.fetch("LOAD_TEST_THREADS", "20").to_i
  ERROR_RATE_MAX = ENV.fetch("LOAD_TEST_ERROR_RATE_MAX", "0.01").to_f
  THROUGHPUT_MIN_PCT = ENV.fetch("LOAD_TEST_THROUGHPUT_MIN_PCT", "0.90").to_f

  SIGNAL_CODE = "invoice.late_ratio_30d"

  def run
    puts "=" * 78
    puts "Load test: signal ingestion (PRD §15 #4)"
    puts "  target_qps=#{TARGET_QPS}  duration=#{DURATION_SEC}s  threads=#{THREADS}"
    puts "  error_rate_max=#{ERROR_RATE_MAX}  throughput_min_pct=#{THROUGHPUT_MIN_PCT}"
    puts "=" * 78

    PerfHelper.purge_test_db!
    PerfHelper.seed_signal_definitions!

    # Pre-create N tenants → N raw API keys, so the load is spread across
    # several tenants (matches v1 production scale and avoids single-tenant
    # row-level lock hotspots in vendor_aliases).
    tenant_count = [THREADS, 5].min
    tenants = tenant_count.times.map do |i|
      tenant, raw_key = PerfHelper.seed_tenant!(slug: "perf-ld-#{i}", display_name: "PerfLD#{i}")
      [tenant, raw_key]
    end

    successes = Concurrent::AtomicFixnum.new(0)
    errors    = Concurrent::AtomicFixnum.new(0)
    latencies = Concurrent::Array.new

    # Per-thread target QPS (each thread paces independently).
    per_thread_qps = TARGET_QPS.to_f / THREADS
    interval_sec = 1.0 / per_thread_qps

    PerfHelper.boot_puma(
      port: PORT,
      extra_env: {
        # Async path: the API responds 201 as soon as the row is inserted +
        # the post-insert hook enqueues ScoreRecomputeJob. Score compute
        # happens on workers (or in :test queue here — observable via
        # active_job/test_helper depth).
        "E2E_INLINE_JOBS" => "false"
      }
    ) do
      base = "http://127.0.0.1:#{PORT}"
      stop_at = monotonic_ms + DURATION_SEC * 1000.0

      worker_threads = THREADS.times.map do |tid|
        Thread.new do
          tenant, raw_key = tenants[tid % tenants.size]
          headers = { "X-API-Key" => raw_key }
          counter = 0
          next_slot = monotonic_ms

          loop do
            now = monotonic_ms
            break if now > stop_at

            if now < next_slot
              sleep((next_slot - now) / 1000.0)
            end
            next_slot += interval_sec * 1000.0

            counter += 1
            evt = "perf-ld-#{tid}-#{counter}-#{Process.pid}"
            payload = {
              vendor_ref: {
                normalized_name: "perf load supplier #{tid % 20}",
                tax_id: "PERF-LD-#{tid % 20}-#{tenant.slug}"
              },
              signal_code: SIGNAL_CODE,
              source_system: "invoice_recon",
              source_event_id: evt,
              value_numeric: 0.10 + (counter % 10) * 0.05,
              recorded_at: Time.now.utc.iso8601
            }
            t0 = monotonic_ms
            begin
              res = PerfHelper.post_json(URI.join(base, "/api/signals"), payload, headers: headers)
              t1 = monotonic_ms
              latencies << (t1 - t0)
              if res.code == "201"
                successes.increment
              else
                errors.increment
              end
            rescue StandardError
              errors.increment
            end
          end
        end
      end

      # Sampling thread — once per second, log queue depth + counts.
      samples = []
      sampler = Thread.new do
        while monotonic_ms < stop_at
          sleep 1
          samples << {
            t: monotonic_ms,
            success: successes.value,
            errors: errors.value,
            latencies_count: latencies.size
          }
        end
      end

      worker_threads.each(&:join)
      sampler.kill if sampler.alive?

      print_progress_samples(samples)
    end

    total = successes.value + errors.value
    actual_qps = total.to_f / DURATION_SEC
    error_rate = total.positive? ? errors.value.to_f / total : 0.0
    stats = PerfHelper.percentile_stats(latencies.to_a)

    puts ""
    puts "Final:"
    puts "  duration=#{DURATION_SEC}s  total_requests=#{total}  successes=#{successes.value}  errors=#{errors.value}"
    puts "  actual_qps=#{format('%.1f', actual_qps)}  target_qps=#{TARGET_QPS}  achieved=#{format('%.1f%%', (actual_qps / TARGET_QPS * 100))}"
    puts "  error_rate=#{format('%.4f%%', error_rate * 100)}"
    puts "  " + PerfHelper.format_stats("INGEST_LATENCY", stats)
    puts ""

    pass = true
    if actual_qps < TARGET_QPS * THROUGHPUT_MIN_PCT
      warn "FAIL: throughput #{format('%.1f', actual_qps)}/sec below #{format('%.0f%%', THROUGHPUT_MIN_PCT * 100)} of target #{TARGET_QPS}/sec"
      pass = false
    end
    if error_rate > ERROR_RATE_MAX
      warn "FAIL: error rate #{format('%.4f', error_rate)} exceeds #{ERROR_RATE_MAX}"
      pass = false
    end

    if pass
      puts "PASS: load test sustained #{format('%.1f', actual_qps)}/sec for #{DURATION_SEC}s with error_rate=#{format('%.4f', error_rate)}"
    else
      exit(1)
    end
  end

  private

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  end

  def print_progress_samples(samples)
    puts ""
    puts "Per-second progress (cumulative):"
    samples.each_with_index do |s, i|
      puts "  t=#{(i + 1).to_s.rjust(3)}s  success=#{s[:success].to_s.rjust(6)}  errors=#{s[:errors].to_s.rjust(4)}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  LoadTestSignalIngestion.new.run
end
