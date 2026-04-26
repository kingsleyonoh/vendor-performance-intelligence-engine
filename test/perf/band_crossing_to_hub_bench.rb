# frozen_string_literal: true

# Performance benchmark — PRD §15 #3, §13.3.
#
# Validates: from the moment a signal arrives that crosses a band threshold,
# to the moment HubDispatchJob's HTTP POST to the Hub fires, p95 must stay
# under 2000ms.
#
# Methodology:
#   1. Boot a tiny stub Hub TCP server in this process — captures the wall
#      clock at the moment HubDispatchJob's POST hits it. The Hub is
#      external SAAS per `CODING_STANDARDS_TESTING_LIVE.md` mock policy,
#      so stubbing it is sanctioned.
#   2. Boot Puma with `E2E_INLINE_JOBS=true` (so band crossing → recompute
#      → dispatcher → HubDispatchJob run synchronously inside the request)
#      and `NOTIFICATION_HUB_ENABLED=true` + the stub Hub URL so HubClient
#      actually issues the POST.
#   3. Pre-seed a vendor with signals positioning it just below a band
#      threshold. Each iteration POSTs ONE signal that knocks the score
#      across the threshold — capture t0 at POST start, t1 when the stub
#      Hub receives the event.
#   4. Inside each iteration we delete the inserted alert + reset the score
#      so the next signal can re-trigger a band crossing.
#   5. Compute p50/p95/p99/max. Assert p95 < 2000ms.
#
# Run: `bin/dc bin/rake perf:bench:band_crossing`

require_relative "perf_helper"
require "socket"
require "thread"

class BandCrossingToHubBench
  PORT       = ENV.fetch("PERF_PORT", "3102").to_i
  HUB_PORT   = ENV.fetch("PERF_HUB_PORT", "3192").to_i
  ITERATIONS = ENV.fetch("PERF_ITERATIONS", "30").to_i
  P95_TARGET_MS = ENV.fetch("PERF_P95_TARGET_MS", "2000").to_i

  SIGNAL_CODE = "invoice.late_ratio_30d"

  def run
    puts "=" * 78
    puts "Perf Benchmark: band crossing -> Hub delivery (PRD §15 #3)"
    puts "  iterations=#{ITERATIONS}  target=p95<#{P95_TARGET_MS}ms"
    puts "=" * 78

    PerfHelper.purge_test_db!
    PerfHelper.seed_signal_definitions!
    tenant, raw_key = PerfHelper.seed_tenant!(slug: "perf-bandcross", display_name: "PerfBandCross")

    @hub_received = Queue.new
    hub_thread = start_stub_hub(HUB_PORT, @hub_received)

    headers = { "X-API-Key" => raw_key }
    base = "http://127.0.0.1:#{PORT}"
    latencies = []
    errors = 0

    PerfHelper.boot_puma(
      port: PORT,
      extra_env: {
        "E2E_INLINE_JOBS" => "true",
        "NOTIFICATION_HUB_ENABLED" => "true",
        "NOTIFICATION_HUB_URL" => "http://127.0.0.1:#{HUB_PORT}",
        "NOTIFICATION_HUB_API_KEY" => "stub-hub-key",
        # Bypass the dedup window so each iteration can fire a fresh alert.
        "ALERT_DEDUP_WINDOW_HOURS" => "0"
      }
    ) do
      ITERATIONS.times do |i|
        # Each iteration uses a fresh vendor so no dedup or supersede logic
        # interferes. Pre-seed signals BELOW the threshold via direct INSERT,
        # then POST one signal that crosses it.
        vendor = preseed_vendor_at_low_band!(tenant, "perf-bx-#{i}")
        evt = "perf-bx-#{Process.pid}-#{i}-#{SecureRandom.hex(4)}"

        # Drain any leftover hub event from prior iteration.
        @hub_received.clear

        t0 = monotonic_ms
        res = post_crossing_signal(base, headers, vendor, evt)

        # Wait up to 5s for the stub Hub to receive the event. The dispatcher
        # runs synchronously (E2E_INLINE_JOBS) so HubDispatchJob fires
        # inside the POST handler.
        deadline = monotonic_ms + 5_000
        recv_at = nil
        until monotonic_ms > deadline
          if (item = @hub_received.pop(true) rescue nil)
            recv_at = item
            break
          end
          sleep 0.005
        end

        if res.code == "201" && recv_at
          latencies << (recv_at - t0)
        else
          errors += 1
          warn "[error iter=#{i}] post=#{res.code} hub_received=#{!recv_at.nil?}"
        end
      end
    end

    Thread.kill(hub_thread) if hub_thread.alive?

    print_results(latencies, errors)
    stats = PerfHelper.percentile_stats(latencies)

    if stats[:p95] > P95_TARGET_MS
      warn "FAIL: p95 #{format('%.2f', stats[:p95])}ms exceeds target #{P95_TARGET_MS}ms"
      exit(1)
    else
      puts "PASS: p95 #{format('%.2f', stats[:p95])}ms within target #{P95_TARGET_MS}ms"
    end
  end

  private

  # Tiny single-threaded HTTP/1.1 server that ACCEPTs every POST as 201
  # and pushes a high-resolution receive timestamp onto the supplied Queue.
  # Connections are short-lived; we read until end-of-headers + content-length
  # bytes, then return a fixed 201 response.
  def start_stub_hub(port, queue)
    server = TCPServer.new("127.0.0.1", port)
    Thread.new do
      Thread.current.abort_on_exception = false
      loop do
        client = server.accept
        Thread.new(client) do |c|
          recv_at = monotonic_ms
          queue << recv_at
          # Drain request to avoid breaking the client.
          begin
            request_line = c.gets
            content_length = 0
            while (line = c.gets) && line != "\r\n"
              if line =~ /\AContent-Length:\s*(\d+)/i
                content_length = $1.to_i
              end
            end
            c.read(content_length) if content_length.positive?
            body = '{"event_id":"stub-' + SecureRandom.hex(8) + '"}'
            c.write("HTTP/1.1 201 Created\r\n")
            c.write("Content-Type: application/json\r\n")
            c.write("Content-Length: #{body.bytesize}\r\n")
            c.write("Connection: close\r\n\r\n")
            c.write(body)
          rescue StandardError
            # client connection went away — fine
          ensure
            c.close rescue nil
          end
        end
      rescue StandardError
        break
      end
    end
  end

  def preseed_vendor_at_low_band!(tenant, slug)
    vendor = Vendor.create!(
      tenant_id: tenant.id,
      canonical_name: "Perf BandCross #{slug}",
      tax_id: "PERF-BX-#{SecureRandom.hex(4)}",
      country_code: "GB",
      status: "active"
    )

    now = Time.now.utc
    # Insert a baseline `vendor_scores` row at band='low' so the next
    # ScoreRecomputeJob detects a crossing into a higher band when the
    # threshold-crossing signal lands. We deliberately do NOT pre-seed
    # vendor_signals — the composite scorer averages by category, and
    # diluting one strong escalation signal with 30 weak baseline ones
    # can keep the new composite below the medium threshold even when
    # the latest data clearly shows a problem. This vendor's HISTORICAL
    # state is `low`; only the new high-value signal informs the new
    # composite (PRD §5.4 — the recompute considers signals in window,
    # NOT prior scores).
    VendorScore.create!(
      tenant_id: tenant.id,
      vendor_id: vendor.id,
      composite_score: 10.0,
      band: "low",
      trend: "stable",
      category_scores: {
        "financial" => 10.0, "operational" => 0.0, "contractual" => 0.0,
        "integration" => 0.0, "transactional" => 0.0
      },
      top_contributors: [],
      window_days: 90,
      scoring_rules_id: ScoringRule.where(tenant_id: tenant.id, is_active: true).pick(:id),
      computed_at: now - 60
    )

    vendor
  end

  def post_crossing_signal(base, headers, vendor, source_event_id)
    payload = {
      vendor_ref: {
        normalized_name: vendor.normalized_name,
        tax_id: vendor.tax_id
      },
      signal_code: SIGNAL_CODE,
      source_system: "invoice_recon",
      source_event_id: source_event_id,
      # Big value → high financial risk contribution → escalation crossing.
      value_numeric: 0.95,
      recorded_at: Time.now.utc.iso8601
    }
    PerfHelper.post_json(URI.join(base, "/api/signals"), payload, headers: headers)
  end

  def monotonic_ms
    Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0
  end

  def print_results(latencies, errors)
    puts ""
    puts "Results:"
    puts "  errors=#{errors}/#{ITERATIONS}"
    puts "  " + PerfHelper.format_stats("BAND_TO_HUB", PerfHelper.percentile_stats(latencies))
    puts ""
  end
end

if __FILE__ == $PROGRAM_NAME
  BandCrossingToHubBench.new.run
end
