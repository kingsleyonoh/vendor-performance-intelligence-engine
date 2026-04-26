# frozen_string_literal: true

# Performance benchmark + load test rake namespace — PRD §15 #2/#3/#4/#8.
#
# Each task boots a fresh Puma over real HTTP and exercises the canonical
# user-facing path. Real Postgres + real Redis. Hub is mocked (external
# SAAS — see CODING_STANDARDS_TESTING_LIVE.md). All other hops are live.
#
# Usage:
#   bin/dc bin/rake perf:bench:roundtrip      # PRD §15 #2 — signal/score 500ms p95
#   bin/dc bin/rake perf:bench:band_crossing  # PRD §15 #3 — alert 2s p95
#   bin/dc bin/rake perf:bench:reports        # PRD §15 #8 — reports <30s
#   bin/dc bin/rake perf:bench:all            # all three latency benches
#   bin/dc bin/rake perf:load                 # PRD §15 #4 — 30s short load test
#   bin/dc bin/rake perf:load:full            # PRD §15 #4 — 10-min full load test
#
# Tunables (per task; see each *_bench.rb file for the full list):
#   PERF_ITERATIONS, PERF_PRESEED_SIGNALS, PERF_VENDOR_COUNT, PERF_PORT,
#   LOAD_TEST_TARGET_QPS, LOAD_TEST_DURATION_SEC, LOAD_TEST_THREADS
#
# Why a subprocess (Process.spawn / system) instead of `Rake::Task[:environment].invoke`?
# `bin/rake` loads `config/boot.rb` BEFORE the task body runs, which freezes
# `Rails.env` to "development". Setting `ENV["RAILS_ENV"]="test"` from inside
# the task body is too late — AR is already pinned to the dev DB while our
# bench's `pg_connect` reads the test DB, which results in seeded rows being
# invisible to the booted Puma. Spawning a fresh ruby with RAILS_ENV in its
# environment sidesteps this entirely and matches `test:e2e`'s ServerBoot
# pattern (the only other place we boot Puma from rake).

def run_perf_bench(script_relative_path)
  script = File.expand_path("../../test/perf/#{script_relative_path}", __dir__)
  # `system(env, ...)` MERGES the supplied hash into the current ENV — keys
  # we don't list (PERF_ITERATIONS, PERF_PORT, etc.) pass through unchanged.
  # We only override the three knobs that MUST be set for the bench to
  # resolve the test DB cleanly.
  env_overrides = {
    "RAILS_ENV" => "test",
    # Suppress dev-container auto-seed/migrate hooks (set by .env.local for
    # dev convenience). They trigger `vpi:setup` inside Rails' after-init
    # hook, which would interleave a "default" tenant create + a `db:seed`
    # iteration of `Tenant.find_each` with our own purge/seed flow. Perf
    # benchmarks own seeding from the ground up.
    "AUTO_SEED" => "false",
    "AUTO_MIGRATE" => "false"
  }
  begin
    ok = system(env_overrides, RbConfig.ruby, script)
    exit(1) unless ok
  ensure
    # Clean up benchmark residue from the test DB so the next `bin/rails test`
    # run does not trip on `check_all_foreign_keys_valid!` against orphaned
    # FK references (the bench creates ~120 vendors + 3500+ signals; leaving
    # them behind violates the fixture loader's referential integrity guard).
    purge_script = File.expand_path("../../test/perf/perf_purge.rb", __dir__)
    system(env_overrides, RbConfig.ruby, purge_script) if File.exist?(purge_script)
  end
end

namespace :perf do
  namespace :bench do
    desc "PRD §15 #2 — signal-ingest -> score-read roundtrip < 500ms p95"
    task :roundtrip do
      run_perf_bench("signal_score_roundtrip_bench.rb")
    end

    desc "PRD §15 #3 — band crossing -> Hub delivery < 2s p95"
    task :band_crossing do
      run_perf_bench("band_crossing_to_hub_bench.rb")
    end

    desc "PRD §15 #8 — every report type < 30s for 100+ vendor tenant"
    task :reports do
      run_perf_bench("report_generation_bench.rb")
    end

    desc "Run all three latency benchmarks sequentially"
    task all: %i[roundtrip band_crossing reports]
  end

  desc "PRD §15 #4 — load test (default 30s short mode; CI-suitable)"
  task :load do
    run_perf_bench("load_test_signal_ingestion.rb")
  end

  namespace :load do
    desc "PRD §15 #4 — load test FULL 10-minute run @ 500 QPS (manual pre-deploy only)"
    task :full do
      ENV["LOAD_TEST_DURATION_SEC"] = "600"
      # Production target per PRD #15 #4. MUST be run against a tuned
      # Puma (WEB_CONCURRENCY=8, RAILS_MAX_THREADS=10) — the dev-container
      # default Puma cannot sustain 500 QPS.
      ENV["LOAD_TEST_TARGET_QPS"] = "500"
      run_perf_bench("load_test_signal_ingestion.rb")
    end
  end
end
