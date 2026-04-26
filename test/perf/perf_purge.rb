# frozen_string_literal: true

# Tear-down helper invoked by `lib/tasks/perf.rake` AFTER every perf benchmark
# completes (success OR failure). Truncates every mutable table in the test
# DB so the next `bin/rails test` invocation can load fixtures cleanly without
# tripping `check_all_foreign_keys_valid!` against benchmark residue.
#
# Loads `config/environment` so the `pg` gem (provided by the bundle) is
# discoverable. A direct `ruby test/perf/perf_purge.rb` would miss the
# bundle and fail on `require "pg"`.

require_relative "../../config/environment"
require_relative "perf_helper"

PerfHelper.purge_test_db!

# Also drain Sidekiq's Redis-backed queues + retry/dead sets. The async
# load test enqueues thousands of `ScoreRecomputeJob` instances; if we
# leave them in Redis, the next `bin/rails test` run trips the `/api/health/ready`
# Sidekiq-depth guard (>1000 → 503).
begin
  require "sidekiq/api"
  Sidekiq::Queue.all.each(&:clear)
  Sidekiq::RetrySet.new.clear
  Sidekiq::DeadSet.new.clear
  Sidekiq::ScheduledSet.new.clear
  puts "[perf_purge] Sidekiq queues drained"
rescue StandardError => e
  warn "[perf_purge] Sidekiq drain failed: #{e.class}: #{e.message}"
end

puts "[perf_purge] test DB cleaned"
