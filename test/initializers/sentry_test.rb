# frozen_string_literal: true

require "test_helper"

# Sentry initializer behavior — PRD §10b, §14.
#
# The initializer in `config/initializers/sentry.rb` MUST:
#   1. Be a no-op when SENTRY_DSN is unset (standalone-first invariant).
#   2. Initialize Sentry when SENTRY_DSN is present, setting environment +
#      release + filtered breadcrumbs.
#   3. Filter sensitive params (api_key, password, token, X-API-Key) via
#      before_send so secrets never leave the host.
#   4. Tag events with tenant_id from Current.tenant&.id.
#
# Sentry is a third-party SAAS — we never call the real Sentry.init in tests.
# The `Vpi::SentryConfig.configure!` method takes an optional `init_proc`
# parameter for tests so we can capture what would have been passed to
# the real Sentry.init.
class SentryInitializerTest < ActiveSupport::TestCase
  def setup
    @original_dsn = ENV["SENTRY_DSN"]
    @original_release = ENV["VPI_VERSION"]
  end

  def teardown
    ENV["SENTRY_DSN"] = @original_dsn
    ENV["VPI_VERSION"] = @original_release
  end

  test "is a no-op when SENTRY_DSN is unset" do
    ENV.delete("SENTRY_DSN")
    init_called = false
    Vpi::SentryConfig.configure!(init_proc: ->(*) { init_called = true })
    assert_equal false, init_called, "Sentry.init must not be called without SENTRY_DSN"
  end

  test "is a no-op when SENTRY_DSN is empty string" do
    ENV["SENTRY_DSN"] = ""
    init_called = false
    Vpi::SentryConfig.configure!(init_proc: ->(*) { init_called = true })
    assert_equal false, init_called
  end

  test "calls Sentry.init when SENTRY_DSN is present" do
    ENV["SENTRY_DSN"] = "https://key@sentry.example.com/1"
    captured = nil
    init_proc = ->(&blk) { captured = Sentry::Configuration.new.tap { |c| blk&.call(c) } }
    Vpi::SentryConfig.configure!(init_proc: init_proc)
    refute_nil captured, "Sentry.init must be called when DSN is present"
    assert_equal "https://key@sentry.example.com/1", captured.dsn.to_s
    assert_equal Rails.env, captured.environment.to_s
  end

  test "release is set from VPI_VERSION env var" do
    ENV["SENTRY_DSN"] = "https://key@sentry.example.com/1"
    ENV["VPI_VERSION"] = "abc123"
    captured = nil
    init_proc = ->(&blk) { captured = Sentry::Configuration.new.tap { |c| blk&.call(c) } }
    Vpi::SentryConfig.configure!(init_proc: init_proc)
    assert_equal "abc123", captured.release
  end

  test "before_send scrubs sensitive params from event" do
    ENV["SENTRY_DSN"] = "https://key@sentry.example.com/1"
    captured = nil
    init_proc = ->(&blk) { captured = Sentry::Configuration.new.tap { |c| blk&.call(c) } }
    Vpi::SentryConfig.configure!(init_proc: init_proc)

    event = { "request" => { "data" => { "api_key" => "vpi_secret_xxx", "password" => "hunter2", "token" => "tk_abc", "ok_field" => "visible" } } }
    result = captured.before_send.call(event, {})

    refute_match(/vpi_secret_xxx/, result.to_json)
    refute_match(/hunter2/, result.to_json)
    refute_match(/tk_abc/, result.to_json)
    assert_match(/visible/, result.to_json)
  end

  test "before_send scrubs X-API-Key header" do
    ENV["SENTRY_DSN"] = "https://key@sentry.example.com/1"
    captured = nil
    init_proc = ->(&blk) { captured = Sentry::Configuration.new.tap { |c| blk&.call(c) } }
    Vpi::SentryConfig.configure!(init_proc: init_proc)

    event = { "request" => { "headers" => { "X-API-Key" => "vpi_live_secret123", "User-Agent" => "test" } } }
    result = captured.before_send.call(event, {})

    refute_match(/vpi_live_secret123/, result.to_json)
    assert_match(/test/, result.to_json)
  end
end
