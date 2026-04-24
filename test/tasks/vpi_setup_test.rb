# frozen_string_literal: true

require "test_helper"
require "rake"

# Tests for `bin/rails vpi:setup` — PRD §11.
#
# Behavior verified:
# - First run creates a default tenant + prints the raw API key ONCE to stdout.
# - Re-runs are idempotent: no duplicate tenants, no re-issued keys, prints an
#   "Already initialized" message.
# - signal_definitions are seeded (delegates to db:seed) and the row count is
#   stable across re-runs.
class VpiSetupTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    # Load the rake tasks once; re-invoke by clearing task's :invoked flag.
    Rake.application.clear
    Rails.application.load_tasks

    # Start from a clean slate: drop any pre-existing tenants inserted by
    # prior tests. Fixtures are loaded at suite-start but each test here must
    # run against an initially-empty tenants table so first-run branch is
    # observable. Use DELETE to also purge has_many :restrict_with_exception
    # children (users/sessions) — fixtures load them too.
    ScoringRule.delete_all
    User.delete_all
    Session.delete_all
    Tenant.delete_all
  end

  teardown do
    # Reset tenant table so the rest of the suite's fixtures re-hydrate
    # deterministically (parallelize off in this file — see below).
    ScoringRule.delete_all
    User.delete_all
    Session.delete_all
    Tenant.delete_all
  end

  # DB-mutation tests shouldn't interleave with parallel fixture-driven tests
  # on the same shared parallel DB (vpi_test-N). Minitest's TestCase-level
  # i_suck_and_my_tests_are_order_dependent! forces sequential.
  i_suck_and_my_tests_are_order_dependent!

  test "first run creates default tenant and prints raw API key to stdout" do
    out, _err = capture_io { Rake::Task["vpi:setup"].execute }

    assert_equal 1, Tenant.count
    tenant = Tenant.first
    assert tenant.slug.present?
    assert tenant.is_active

    # Raw key in stdout is a one-time print.
    assert_match(/vpi_/, out, "first-run output must include the raw API key")
    assert_match(/X-API-Key/i, out, "first-run output must instruct on header usage")

    # The default tenant MUST now have an active scoring_rule (PRD §4.7).
    active_rule = ScoringRule.find_by(tenant_id: tenant.id, is_active: true)
    assert active_rule, "default tenant must have an active scoring_rule after setup"
    assert_equal "Default v1", active_rule.name

    # Stored hash must be SHA-256 of the raw key — extract the key token
    # (alphanumerics, `_`, `-` — the urlsafe_base64 alphabet plus our
    # `_` separators) from stdout and verify.
    raw = out.scan(/vpi_[A-Za-z0-9_\-]+/).first
    assert raw, "could not locate raw key in output: #{out.inspect}"
    assert_equal Digest::SHA256.hexdigest(raw), tenant.api_key_hash
  end

  test "five reruns produce identical state (idempotent)" do
    # First run seeds.
    capture_io { Rake::Task["vpi:setup"].execute }
    seed_tenant_count = Tenant.count
    seed_signal_count = SignalDefinition.count
    assert_equal 1, seed_tenant_count
    assert seed_signal_count.positive?

    4.times do
      out, _err = capture_io { Rake::Task["vpi:setup"].execute }
      # Subsequent runs MUST NOT print a raw key.
      # Check for the full-key shape (env-prefix + underscore + suffix + _ + base64 secret)
      # rather than the short-prefix shape which appears in the "tenant: slug"
      # line. Minimum realistic full-key length is ~40 chars.
      refute_match(/vpi_[A-Za-z0-9_\-]{30,}/, out,
                   "re-runs must not print a raw API key; got: #{out.inspect}")
      assert_match(/Already initialized/i, out)
    end

    assert_equal seed_tenant_count, Tenant.count
    assert_equal seed_signal_count, SignalDefinition.count
  end
end
