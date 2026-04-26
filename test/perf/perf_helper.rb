# frozen_string_literal: true

# PerfHelper — shared infrastructure for `test/perf/*_bench.rb`.
#
# These benchmarks validate PRD §15 acceptance criteria #2/#3/#4/#8 over a
# REAL Puma server, REAL Postgres, REAL Redis. Per the mock policy in
# `CODING_STANDARDS_TESTING_LIVE.md`, only the Notification Hub (external
# SAAS) is allowed to be stubbed — every internal hop must be live.
#
# Why a fresh harness instead of reusing `test/support/server_boot.rb`?
#   - ServerBoot truncates the test DB at every spawn — perf benchmarks need
#     to pre-seed thousands of rows BEFORE Puma comes up so the seed itself
#     isn't part of the latency budget.
#   - Perf benchmarks select a port that doesn't collide with parallel
#     E2E runs (`E2E_PORT=3001` is reserved by `bin/rake test:e2e`).
#   - Perf benchmarks pin extra env (e.g. `E2E_INLINE_JOBS=true` for
#     synchronous score recompute in items 1+2; explicitly OFF for item 4).

require "net/http"
require "uri"
require "json"
require "pg"
require "digest/sha2"
require "securerandom"
require "benchmark"

module PerfHelper
  extend self

  # -----------------------------------------------------------------------
  # Statistics
  # -----------------------------------------------------------------------

  # Returns a hash of {p50:, p95:, p99:, max:, min:, mean:, count:}. Latencies
  # in milliseconds (Float). NaN-safe for empty arrays (returns zeros).
  def percentile_stats(latencies_ms)
    return zero_stats if latencies_ms.empty?

    sorted = latencies_ms.sort
    {
      count: sorted.size,
      min: sorted.first,
      max: sorted.last,
      mean: sorted.sum.to_f / sorted.size,
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99)
    }
  end

  def zero_stats
    { count: 0, min: 0.0, max: 0.0, mean: 0.0, p50: 0.0, p95: 0.0, p99: 0.0 }
  end

  # Linear-interpolation percentile (matches numpy.percentile default).
  def percentile(sorted, p)
    return 0.0 if sorted.empty?
    return sorted.first if sorted.size == 1

    rank = p * (sorted.size - 1)
    lower = rank.floor
    upper = rank.ceil
    return sorted[lower].to_f if lower == upper

    weight = rank - lower
    (sorted[lower] * (1 - weight) + sorted[upper] * weight).to_f
  end

  def format_stats(label, stats)
    "#{label.ljust(20)}  count=#{stats[:count].to_s.rjust(5)}  " \
      "min=#{format('%.2f', stats[:min])}ms  " \
      "p50=#{format('%.2f', stats[:p50])}ms  " \
      "p95=#{format('%.2f', stats[:p95])}ms  " \
      "p99=#{format('%.2f', stats[:p99])}ms  " \
      "max=#{format('%.2f', stats[:max])}ms  " \
      "mean=#{format('%.2f', stats[:mean])}ms"
  end

  # -----------------------------------------------------------------------
  # Direct Postgres connection (bypasses Rails transactional fixtures)
  # -----------------------------------------------------------------------

  # Opens a fresh PG connection against the TEST database. Caller must
  # `.close` it when done. We bypass Rails' connection pool because the
  # Puma subprocess holds its own pool and we need writes to be visible
  # to it without a transaction wrap.
  def pg_connect
    require_relative "../../config/environment" unless defined?(Rails)
    cfg = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
    PG.connect(
      host: cfg.configuration_hash[:host],
      port: cfg.configuration_hash[:port],
      dbname: cfg.configuration_hash[:database],
      user: cfg.configuration_hash[:username],
      password: cfg.configuration_hash[:password]
    )
  end

  # Truncate every mutable row so each benchmark starts from a known state.
  # Order matters: children before parents (every FK points up to tenants).
  def purge_test_db!
    pg = pg_connect
    %w[
      risk_alerts vendor_reports vendor_scores vendor_signals vendor_aliases
      vendors scoring_rules ingestion_runs ingestion_sources sessions users
      tenants
    ].each do |tbl|
      pg.exec("TRUNCATE #{tbl} CASCADE")
    rescue PG::Error
      # missing table — ignore
    end
  ensure
    pg&.close
  end

  # Bulk-INSERT vendor_signals via raw SQL. The `vendor_signals` table is
  # partitioned by month on `recorded_at`; ActiveRecord's `insert_all` cannot
  # find a unique index on the partitioned PK shape, so it raises. Raw SQL
  # via PG#exec_params bypasses the AR insert_all machinery and is faster
  # anyway when seeding 100s/1000s of rows for a benchmark.
  #
  # Returns the number of rows inserted.
  def bulk_insert_signals!(tenant_id:, vendor_id:, signal_code:, count:,
                            value_proc:, age_seconds_proc:, tag:,
                            signal_definition_id: nil, value_type: nil)
    # signal_definition_id / value_type kwargs accepted for caller-side
    # readability + forward compatibility. The actual schema (PRD §4.5) does
    # NOT carry those columns on `vendor_signals` — `signal_code` references
    # `signal_definitions.code` directly, and the value type is implied by
    # which `value_*` column is populated.
    pg = pg_connect
    now = Time.now.utc
    sql = <<~SQL
      INSERT INTO vendor_signals (
        id, tenant_id, vendor_id, signal_code,
        source_system, source_event_id, value_numeric,
        recorded_at, status, context, created_at
      ) VALUES (
        gen_random_uuid(), $1, $2, $3,
        'invoice_recon', $4, $5,
        $6, 'normalized', '{}'::jsonb, $7
      )
    SQL
    pg.prepare("perf_bulk_insert_signals", sql)
    inserted = 0
    count.times do |i|
      pg.exec_prepared("perf_bulk_insert_signals", [
        tenant_id,
        vendor_id,
        signal_code,
        "#{tag}-#{i}-#{SecureRandom.hex(4)}",
        value_proc.call(i),
        (now - age_seconds_proc.call(i)).iso8601(6),
        now.iso8601(6)
      ])
      inserted += 1
    end
    inserted
  ensure
    pg&.close
  end

  # Ensures `signal_definitions` is seeded. Safe to call repeatedly.
  def seed_signal_definitions!
    require_relative "../../config/environment" unless defined?(Rails)
    return if SignalDefinition.count.positive?

    require "yaml"
    YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each do |row|
      SignalDefinition.find_or_create_by!(code: row["code"]) do |sd|
        sd.assign_attributes(row)
      end
    end
  end

  # Create a tenant + active scoring rule + return the raw API key.
  # Uses ::Tenants::ApiKeyGenerator so the SHA-256 hash matches what the
  # API key middleware constant-time-compares against.
  #
  # The slug receives a random suffix so each call is collision-proof
  # against prior-run residue, against AUTO_SEED tenants the auto_boot
  # hook may have created during :environment load, and against parallel
  # benches sharing the same DB.
  def seed_tenant!(slug:, display_name:)
    require_relative "../../config/environment" unless defined?(Rails)

    unique_slug = "#{slug}-#{SecureRandom.hex(4)}"

    key = ::Tenants::ApiKeyGenerator.generate
    tenant = Tenant.create!(
      slug: unique_slug,
      name: display_name,
      legal_name: display_name,
      full_legal_name: "#{display_name} Ltd",
      display_name: display_name,
      address: { line1: "1 Perf St", city: "BenchTown", country_code: "GB" },
      registration: { tax_id: "PERF-#{unique_slug.upcase}", company_number: "PERF-#{unique_slug.upcase}-001" },
      contact: { email: "perf+#{unique_slug}@example.test" },
      brand_primary_hex: "#000000",
      brand_accent_hex: "#FF0000",
      locale: "en-US",
      timezone: "UTC",
      is_active: true,
      api_key_hash: key.api_key_hash,
      api_key_prefix: key.api_key_prefix,
      settings: {}
    )
    ScoringRule.create!(
      tenant_id: tenant.id,
      name: "Default v1",
      is_active: true,
      category_weights: {
        "financial" => 0.35, "operational" => 0.10, "contractual" => 0.30,
        "integration" => 0.10, "transactional" => 0.15
      },
      band_thresholds: { "low_max" => 30, "medium_max" => 60, "high_max" => 85 },
      window_days: 90,
      time_decay_half_life_days: 45
    )
    [tenant, key.raw_key]
  end

  # -----------------------------------------------------------------------
  # Puma boot
  # -----------------------------------------------------------------------

  # Boots a real Puma on the given port with the supplied env, waits for
  # `/up` readiness, yields the pid, then cleanly TERMs it.
  #
  # extra_env keys are *added* to the Puma subprocess env. Pre-set defaults
  # (`RAILS_ENV=test`, `HUB_INGRESS_SECRET`, `RACK_ATTACK_REGISTER_LIMIT`)
  # mirror the existing E2E ServerBoot config so perf benchmarks behave
  # identically to E2E from a routing/middleware perspective.
  def boot_puma(port:, extra_env: {})
    env = {
      "RAILS_ENV" => "test",
      "PORT" => port.to_s,
      "HUB_INGRESS_SECRET" => "perf-hub-ingress-secret-32bytes!",
      "RACK_ATTACK_REGISTER_LIMIT" => "1000",
      # Perf benchmarks register tenants then fire 100s of POSTs/sec under
      # one X-API-Key. Bypass per-tenant signal/read tier caps so the
      # benchmark measures the application path, not the Rack::Attack
      # rate-limiter (which is exercised by separate dedicated tests).
      "RACK_ATTACK_DISABLE" => "true",
      # Suppress dev-container auto-seed/migrate hooks inside the booted
      # Puma — perf seeds are owned by the driver process and any
      # interleaved auto-seed pollutes the test DB mid-bench.
      "AUTO_SEED" => "false",
      "AUTO_MIGRATE" => "false"
    }.merge(extra_env)
    pid = nil
    begin
      pid = Process.spawn(
        env,
        "bin/rails", "server", "-p", port.to_s, "-b", "127.0.0.1",
        out: File::NULL, err: File::NULL
      )
      wait_ready("http://127.0.0.1:#{port}/up", timeout: 60)
      yield pid
    ensure
      if pid
        begin
          Process.kill("TERM", pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          # already gone
        end
      end
    end
  end

  def wait_ready(url, timeout:)
    deadline = Time.now + timeout
    uri = URI(url)
    until Time.now > deadline
      begin
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |h|
          h.get(uri.request_uri)
        end
        return true if response.code == "200"
      rescue StandardError
        # Server not up yet
      end
      sleep 0.5
    end
    raise "Puma did not become ready on #{url} within #{timeout}s"
  end

  # -----------------------------------------------------------------------
  # HTTP convenience
  # -----------------------------------------------------------------------

  def post_json(uri, body, headers: {})
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = body.to_json
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.request(req)
    end
  end

  def get(uri, headers: {})
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      http.request(req)
    end
  end
end
