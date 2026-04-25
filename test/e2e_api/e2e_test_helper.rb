# frozen_string_literal: true

# Shared helper for all test/e2e_api/*_test.rb files.
#
# E2E tests write rows to the TEST database via the Puma subprocess —
# those writes commit autonomously (autocommit outside the test-process
# transaction). The default ActiveSupport::TestCase inherited behavior
# then clashes with those committed rows in two ways:
#
#   1. `fixtures :all` (set in test_helper.rb) calls
#      `check_all_foreign_keys_valid!` which blows up on orphaned FKs
#      pointing at tenants that were deleted in a prior run.
#
#   2. `use_transactional_tests = true` opens a transaction the Puma
#      connection can't see, so Puma reads nothing the test just wrote.
#
# `e2e_test_case!` on the test class turns off fixtures + the transaction
# wrapper AND registers a per-test purge that truncates the test DB via a
# dedicated connection. Call it inside every E2E test class body.
module E2ETestHelper
  PURGE_TABLES = %w[
    risk_alerts
    vendor_scores
    vendor_signals
    vendor_aliases
    vendors
    scoring_rules
    ingestion_runs
    ingestion_sources
    sessions
    users
    tenants
  ].freeze

  def self.included(base)
    base.extend ClassMethods
    base.class_eval do
      # Opt out of transactional fixtures — Puma lives on its own connection.
      self.use_transactional_tests = false
      # Opt out of the fixture loader entirely. E2E tests do not use the
      # `tenants.yml` / `users.yml` fixtures; they register tenants over
      # real HTTP. Rails 8 needs both hooks zeroed to skip `fixtures :all`.
      self.set_fixture_class({})
      self.fixture_table_names = []
      self.test_order = :sorted
      parallelize(workers: 1)
    end
  end

  module ClassMethods
    # Placeholder for future class-level hooks. All meaningful setup is
    # module-level now — keep this here so future E2E tests can add
    # overrides without blowing past ≥300 lines per file.
  end

  # Purge all mutable state via a dedicated PG connection — bypasses
  # transactional-fixture scaffolding. Order matters: children before
  # parents (every FK points up to tenants).
  def purge_test_db!
    cfg = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
    pg = PG.connect(
      host: cfg.configuration_hash[:host],
      port: cfg.configuration_hash[:port],
      dbname: cfg.configuration_hash[:database],
      user: cfg.configuration_hash[:username],
      password: cfg.configuration_hash[:password]
    )
    PURGE_TABLES.each do |tbl|
      pg.exec("DELETE FROM #{tbl}")
    rescue PG::Error
      # Missing table in some environments — ignore.
    end
  ensure
    pg&.close
  end
end
