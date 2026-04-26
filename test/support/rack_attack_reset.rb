# frozen_string_literal: true

# Per-test reset for Rack::Attack throttle counters. Loaded by
# `test/test_helper.rb` and applied to every `ActionDispatch::IntegrationTest`
# subclass via a `setup`/`teardown` pair so individual test files do not need
# bespoke teardown blocks.
#
# Why this exists: Batch 029 tightened per-endpoint throttles to PRD §8b
# (rotate-key 2/min, scoring_rules write 10/min, vendors write 60/min, etc.).
# Several existing test files exercise multiple writes against the same
# tenant and tripped the new caps. Rather than scattering Rack::Attack
# resets across every controller test, we centralize it here.
#
# Behavior:
#   - setup: snapshot the current store; swap in an isolated MemoryStore
#     so counters do not leak across parallel forks (the production store
#     is a Redis proxy shared by every worker via the same Redis instance).
#   - teardown: restore the original store handle.
#
# The `RateLimitSmokeTest` and `RateLimitPerEndpointTest`'s
# `RateLimitWriteTierLiveTest` files manage their own Rack::Attack state
# explicitly — opting out via `RACK_ATTACK_TEST_RESET=skip` via a class
# annotation (`self.rack_attack_reset_skip = true`). Default is to apply
# the reset.
module RackAttackReset
  def self.included(base)
    base.class_attribute :rack_attack_reset_skip, default: false
    base.setup     { RackAttackReset.before(self) }
    base.teardown  { RackAttackReset.after(self) }
  end

  def self.before(test)
    return if test.rack_attack_reset_skip

    test.instance_variable_set(:@_rack_attack_prev_store, Rack::Attack.cache.store)
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  def self.after(test)
    return if test.rack_attack_reset_skip

    prev = test.instance_variable_get(:@_rack_attack_prev_store)
    Rack::Attack.cache.store = prev if prev
  end
end

ActionDispatch::IntegrationTest.include(RackAttackReset)
