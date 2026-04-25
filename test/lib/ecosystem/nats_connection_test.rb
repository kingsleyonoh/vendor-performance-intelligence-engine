# frozen_string_literal: true

require "test_helper"

# Ecosystem::NatsConnection — singleton NATS JetStream connection (PRD §6 + §13.2).
#
# Standalone-first: when NATS_ENABLED != "true", `.instance` returns nil
# and any subscriber must exit immediately without making network calls.
#
# Real-NATS connection testing is an integration concern — these tests
# stub the underlying NATS::IO::Client to verify lifecycle, flag
# honoring, and shutdown idempotency without standing up a NATS server.
class NatsConnectionTest < ActiveSupport::TestCase
  setup do
    @prev_enabled = ENV["NATS_ENABLED"]
    @prev_url     = ENV["NATS_URL"]
    @prev_creds   = ENV["NATS_CREDS_PATH"]
    @prev_stream  = ENV["NATS_STREAM_NAME"]
    Ecosystem::NatsConnection.shutdown # clear any prior state
  end

  teardown do
    Ecosystem::NatsConnection.shutdown
    ENV["NATS_ENABLED"]     = @prev_enabled
    ENV["NATS_URL"]         = @prev_url
    ENV["NATS_CREDS_PATH"]  = @prev_creds
    ENV["NATS_STREAM_NAME"] = @prev_stream
  end

  test "disabled — .enabled? false, .instance nil, no socket activity" do
    ENV["NATS_ENABLED"] = "false"
    refute Ecosystem::NatsConnection.enabled?
    assert_nil Ecosystem::NatsConnection.instance
  end

  test "stream_name reads from NATS_STREAM_NAME env" do
    ENV["NATS_STREAM_NAME"] = "MY_STREAM"
    assert_equal "MY_STREAM", Ecosystem::NatsConnection.stream_name
  end

  test "stream_name defaults to CONTRACT_LIFECYCLE when env unset" do
    ENV.delete("NATS_STREAM_NAME")
    assert_equal "CONTRACT_LIFECYCLE", Ecosystem::NatsConnection.stream_name
  end

  test "url reads from NATS_URL env" do
    ENV["NATS_URL"] = "nats://nats.example.test:4222"
    assert_equal "nats://nats.example.test:4222", Ecosystem::NatsConnection.url
  end

  test "creds_path reads from NATS_CREDS_PATH env" do
    ENV["NATS_CREDS_PATH"] = "/etc/test/nats.creds"
    assert_equal "/etc/test/nats.creds", Ecosystem::NatsConnection.creds_path
  end

  test "boot! — disabled is a no-op, returns nil" do
    ENV["NATS_ENABLED"] = "false"
    assert_nil Ecosystem::NatsConnection.boot!
    assert_nil Ecosystem::NatsConnection.instance
  end

  test "boot! — enabled connects via injected client_factory" do
    ENV["NATS_ENABLED"] = "true"
    ENV["NATS_URL"] = "nats://localhost:4222"

    fake_client = Object.new
    fake_client.define_singleton_method(:connect) { |opts| @last_opts = opts }
    fake_client.define_singleton_method(:last_opts) { @last_opts }
    fake_client.define_singleton_method(:close) { @closed = true }
    fake_client.define_singleton_method(:closed?) { @closed == true }
    fake_client.define_singleton_method(:jetstream) { :jetstream_handle }

    Ecosystem::NatsConnection.client_factory = -> { fake_client }
    instance = Ecosystem::NatsConnection.boot!
    assert_equal fake_client, instance
    assert_equal fake_client, Ecosystem::NatsConnection.instance
    assert_equal "nats://localhost:4222", fake_client.last_opts[:servers].first
  ensure
    Ecosystem::NatsConnection.client_factory = nil
  end

  test "boot! — connection failure logs but does not raise" do
    ENV["NATS_ENABLED"] = "true"

    failing = Object.new
    failing.define_singleton_method(:connect) { |_opts| raise "kaboom" }

    Ecosystem::NatsConnection.client_factory = -> { failing }

    # Must not raise — we want app boot to survive NATS unavailability.
    assert_nothing_raised do
      Ecosystem::NatsConnection.boot!
    end
    assert_nil Ecosystem::NatsConnection.instance
  ensure
    Ecosystem::NatsConnection.client_factory = nil
  end

  test "shutdown — idempotent (safe to call multiple times)" do
    fake = Object.new
    closed_count = 0
    fake.define_singleton_method(:close) { closed_count += 1 }
    fake.define_singleton_method(:closed?) { closed_count > 0 }

    Ecosystem::NatsConnection.instance = fake
    Ecosystem::NatsConnection.shutdown
    Ecosystem::NatsConnection.shutdown # second call must not blow up
    assert_nil Ecosystem::NatsConnection.instance
    assert closed_count >= 1
  end

  test "shutdown — when nothing connected, does not raise" do
    Ecosystem::NatsConnection.instance = nil
    assert_nothing_raised { Ecosystem::NatsConnection.shutdown }
  end

  test "creds_path passed to connect when set" do
    ENV["NATS_ENABLED"] = "true"
    ENV["NATS_CREDS_PATH"] = "/tmp/test.creds"
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:connect) { |opts| captured = opts }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    Ecosystem::NatsConnection.client_factory = -> { fake }
    Ecosystem::NatsConnection.boot!
    assert_equal "/tmp/test.creds", captured[:user_credentials]
  ensure
    Ecosystem::NatsConnection.client_factory = nil
  end

  test "creds_path NOT passed when env unset" do
    ENV["NATS_ENABLED"] = "true"
    ENV.delete("NATS_CREDS_PATH")
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:connect) { |opts| captured = opts }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }

    Ecosystem::NatsConnection.client_factory = -> { fake }
    Ecosystem::NatsConnection.boot!
    refute captured.key?(:user_credentials)
  ensure
    Ecosystem::NatsConnection.client_factory = nil
  end
end
