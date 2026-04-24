require "net/http"
require "uri"

# Boots a real Puma server via `bin/rails server` on a dedicated port, waits
# for `/up` readiness, yields to the caller (who runs E2E tests against it),
# and guarantees a clean SIGTERM shutdown on the way out.
#
# This is distinct from Rails' in-process `ActionDispatch::IntegrationTest`:
# E2E tests under `test/e2e_api/` hit a running server over real HTTP, which
# is what `CODING_STANDARDS_TESTING_E2E.md` mandates for endpoint batches.
# The `test:e2e` rake task (lib/tasks/test.rake) wraps this helper.
module ServerBoot
  extend self

  DEFAULT_PORT = 3001
  READINESS_TIMEOUT_SECONDS = 30

  # Boots Puma, waits for readiness, yields the pid, then cleans up.
  #   ServerBoot.boot(port: 3001) { |pid| run_tests }
  def boot(port: DEFAULT_PORT)
    purge_orphaned_test_data!
    pid = spawn_server(port)
    wait_ready("http://127.0.0.1:#{port}/up", timeout: READINESS_TIMEOUT_SECONDS)
    seed_signal_definitions_if_empty
    yield pid
  ensure
    shutdown(pid) if pid
    # Truncate again on the way out so `bin/rails test:system` + normal
    # unit test runs don't trip on residue committed by Puma during E2E.
    begin
      purge_orphaned_test_data!
    rescue StandardError
      # best effort
    end
  end

  # Prior E2E runs commit rows into the TEST database via a dedicated PG
  # connection that bypasses Rails' transactional fixtures. On the next
  # run, Rails' fixture FK validator refuses to reload `tenants` because
  # `scoring_rules` / `vendor_signals` / etc. still reference old tenant
  # ids from those earlier runs. Purge that residue before boot so the
  # next fixture-load is clean.
  def purge_orphaned_test_data!
    require_relative "../../config/environment"
    require "active_record"

    test_config = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
    prev_config = ActiveRecord::Base.connection_db_config
    ActiveRecord::Base.establish_connection(test_config)

    # TRUNCATE is used instead of DELETE because the vendor_signals
    # append-only trigger blocks row-level DELETE — TRUNCATE bypasses
    # the per-row trigger and also cascades FK references cleanly.
    tables = %w[
      vendor_scores
      vendor_signals
      vendor_aliases
      vendors
      scoring_rules
      sessions
      users
      tenants
    ]
    ActiveRecord::Base.connection.execute(
      "TRUNCATE #{tables.join(', ')} CASCADE"
    )

    warn "[ServerBoot] purged test DB residue"
  rescue StandardError => e
    warn "[ServerBoot] purge skipped: #{e.class}: #{e.message}"
  ensure
    ActiveRecord::Base.establish_connection(prev_config) if prev_config
  end

  # Seed the system catalog if empty. E2E tests run under RAILS_ENV=test,
  # which does NOT load `db:seed` by default. The Puma subprocess reads
  # `signal_definitions` during ingestion, so any signal-touching E2E test
  # requires this catalog. Fixtures only populate tenants + users; this
  # helper closes the gap without turning off transactional fixtures
  # (which would leak data across tests).
  def seed_signal_definitions_if_empty
    require_relative "../../config/environment"
    require "active_record"

    # The rake task may have loaded the default (development) environment.
    # E2E needs seeds in the TEST DB. Re-establish the connection against
    # the test database configuration and perform the seed write there.
    prev_config = ActiveRecord::Base.connection_db_config
    test_config = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
    ActiveRecord::Base.establish_connection(test_config)

    warn "[ServerBoot] seeding signal_definitions (adapter=#{ActiveRecord::Base.connection_db_config.database})"
    if SignalDefinition.count.zero?
      require "yaml"
      YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each do |row|
        SignalDefinition.find_or_create_by!(code: row["code"]) do |sd|
          sd.assign_attributes(row)
        end
      end
      warn "[ServerBoot] seeded #{SignalDefinition.count} signal_definitions rows"
    else
      warn "[ServerBoot] signal_definitions already has #{SignalDefinition.count} rows"
    end

    # For every tenant (including ones registered by prior E2E tests),
    # ensure a default active scoring_rule exists so ScoreRecomputeJob
    # does not raise on missing rule. Phase 1 has a pending [DATA] item
    # to create this rule automatically at tenant registration; until
    # that lands, the E2E boot seeds it defensively here.
    Tenant.find_each do |tenant|
      next if ScoringRule.where(tenant_id: tenant.id, is_active: true).exists?

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
    end
  rescue StandardError => e
    warn "[ServerBoot] signal_definitions seed skipped: #{e.class}: #{e.message}"
  ensure
    ActiveRecord::Base.establish_connection(prev_config) if prev_config
  end

  private

  def spawn_server(port)
    env = {
      "RAILS_ENV" => "test",
      "PORT" => port.to_s,
      # Run background jobs inline inside request handlers so E2E tests
      # that assert on job side-effects (ScoreRecomputeJob -> vendor_scores)
      # observe those writes synchronously, without needing a Sidekiq worker.
      "E2E_INLINE_JOBS" => "true"
    }
    Process.spawn(
      env,
      "bin/rails", "server", "-p", port.to_s, "-b", "127.0.0.1",
      out: File::NULL, err: File::NULL
    )
  end

  def wait_ready(url, timeout:)
    deadline = Time.now + timeout
    uri = URI(url)
    until Time.now > deadline
      begin
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 2) do |http|
          http.get(uri.request_uri)
        end
        return true if response.code == "200"
      rescue StandardError
        # Server not up yet; retry until deadline.
      end
      sleep 0.5
    end
    raise "Puma did not become ready on #{url} within #{timeout}s"
  end

  def shutdown(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # Already gone — nothing to clean up.
  end
end
