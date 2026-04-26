# frozen_string_literal: true

require "test_helper"

# ContractLifecycleNatsConsumerJob — PRD §6 + §6b + §7.
#
# Long-running Sidekiq worker that subscribes to the JetStream subject
# `contract.obligation.>` and routes each message through the standard
# `Ingestion::SignalIngester` pipeline. Standalone-first: when
# NATS_ENABLED != "true", the job exits immediately as a no-op.
#
# Tests stub `NatsConnection` + a fake JetStream subscription so we can
# exercise ack-vs-nack semantics without standing up a real NATS server.
class Ingestion::ContractLifecycleNatsConsumerJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    ensure_signal_catalog
    @vendor = Vendor.create!(
      tenant: @tenant,
      canonical_name: "ContractCo GmbH",
      tax_id: "DE-CONTRACT-#{SecureRandom.hex(3)}",
      status: "active"
    )
    @prev_enabled = ENV["NATS_ENABLED"]
    @prev_instance = Ecosystem::NatsConnection.instance
  end

  teardown do
    Current.tenant = nil
    ENV["NATS_ENABLED"] = @prev_enabled
    Ecosystem::NatsConnection.instance = @prev_instance
  end

  test "disabled — returns :skipped, no subscription" do
    ENV["NATS_ENABLED"] = "false"
    Ecosystem::NatsConnection.instance = nil

    result = Ingestion::ContractLifecycleNatsConsumerJob.new.perform
    assert_equal :skipped, result
  end

  test "no instance — returns :skipped (NATS unreachable)" do
    ENV["NATS_ENABLED"] = "true"
    Ecosystem::NatsConnection.instance = nil

    result = Ingestion::ContractLifecycleNatsConsumerJob.new.perform
    assert_equal :skipped, result
  end

  test "happy path — message acked + signal stored" do
    ENV["NATS_ENABLED"] = "true"
    msg = build_msg(
      "contract.obligation.breach",
      tenant_slug: @tenant.slug,
      vendor_ref: @vendor.tax_id,
      signal_code: "contract.obligation_breach_count_90d",
      value_numeric: 4
    )
    fake = build_fake_connection([msg])
    Ecosystem::NatsConnection.instance = fake

    Ingestion::ContractLifecycleNatsConsumerJob.new.perform(once: true)

    assert msg.acked?, "message should be acked"
    refute msg.nacked?, "message should NOT be nacked"
    assert VendorSignal
      .where(tenant_id: @tenant.id, signal_code: "contract.obligation_breach_count_90d")
      .exists?, "expected signal to be stored"
  end

  test "bad payload (malformed JSON) — acked + audit logged (no redelivery garbage)" do
    ENV["NATS_ENABLED"] = "true"
    msg = build_msg_raw("contract.obligation.breach", "{this is not json")
    fake = build_fake_connection([msg])
    Ecosystem::NatsConnection.instance = fake

    Ingestion::ContractLifecycleNatsConsumerJob.new.perform(once: true)

    assert msg.acked?, "malformed JSON must be acked (no redelivery)"
    refute msg.nacked?
  end

  test "tenant not found — acked (don't redeliver garbage)" do
    ENV["NATS_ENABLED"] = "true"
    msg = build_msg(
      "contract.obligation.breach",
      tenant_slug: "nonexistent-tenant-#{SecureRandom.hex(3)}",
      vendor_ref: "any",
      signal_code: "contract.obligation_breach_count_90d",
      value_numeric: 1
    )
    fake = build_fake_connection([msg])
    Ecosystem::NatsConnection.instance = fake

    Ingestion::ContractLifecycleNatsConsumerJob.new.perform(once: true)

    assert msg.acked?, "unknown tenant must be acked (terminal — don't redeliver)"
    refute msg.nacked?
  end

  test "transient DB error — message nacked for redelivery" do
    ENV["NATS_ENABLED"] = "true"
    msg = build_msg(
      "contract.obligation.breach",
      tenant_slug: @tenant.slug,
      vendor_ref: @vendor.tax_id,
      signal_code: "contract.obligation_breach_count_90d",
      value_numeric: 1
    )
    fake = build_fake_connection([msg])
    Ecosystem::NatsConnection.instance = fake

    # Force SignalIngester.call to raise a transient error.
    Ingestion::SignalIngester.singleton_class.send(:alias_method, :__orig_call, :call)
    Ingestion::SignalIngester.define_singleton_method(:call) do |**_kwargs|
      raise ActiveRecord::ConnectionNotEstablished, "db down"
    end
    begin
      Ingestion::ContractLifecycleNatsConsumerJob.new.perform(once: true)
    ensure
      Ingestion::SignalIngester.singleton_class.send(:alias_method, :call, :__orig_call)
      Ingestion::SignalIngester.singleton_class.send(:remove_method, :__orig_call)
    end

    refute msg.acked?, "transient errors must NOT ack (allow redelivery)"
    assert msg.nacked?, "transient errors must nack for redelivery"
  end

  test "stop signal halts loop after current message" do
    ENV["NATS_ENABLED"] = "true"
    msgs = [
      build_msg("contract.obligation.breach",
                tenant_slug: @tenant.slug,
                vendor_ref: @vendor.tax_id,
                signal_code: "contract.obligation_breach_count_90d",
                value_numeric: 1),
      build_msg("contract.obligation.breach",
                tenant_slug: @tenant.slug,
                vendor_ref: @vendor.tax_id,
                signal_code: "contract.obligation_breach_count_90d",
                value_numeric: 2)
    ]
    fake = build_fake_connection(msgs)
    Ecosystem::NatsConnection.instance = fake

    job = Ingestion::ContractLifecycleNatsConsumerJob.new
    # Stop after the first message
    job.instance_variable_set(:@stop_after, 1)
    job.perform

    assert msgs.first.acked?
    refute msgs.last.acked?, "second message must not be processed once stop flag set"
  end

  # ====================================================================
  # Helpers
  # ====================================================================

  private

  def ensure_signal_catalog
    return if SignalDefinition.exists?
    YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each { |row| SignalDefinition.create!(row) }
  end

  def build_msg(subject, tenant_slug:, vendor_ref:, signal_code:, value_numeric:)
    body = {
      "tenant_slug" => tenant_slug,
      "vendor_ref" => { "tax_id" => vendor_ref },
      "signal_code" => signal_code,
      "source_event_id" => "nats:#{SecureRandom.uuid}",
      "value_numeric" => value_numeric,
      "recorded_at" => Time.now.utc.iso8601,
      "window_start" => (Time.now.utc - 90 * 86_400).iso8601,
      "window_end" => Time.now.utc.iso8601
    }.to_json
    build_msg_raw(subject, body)
  end

  def build_msg_raw(subject, raw_body)
    msg = Object.new
    msg.instance_variable_set(:@subject, subject)
    msg.instance_variable_set(:@data, raw_body)
    msg.instance_variable_set(:@acked, false)
    msg.instance_variable_set(:@nacked, false)
    msg.define_singleton_method(:subject) { @subject }
    msg.define_singleton_method(:data) { @data }
    msg.define_singleton_method(:ack) { @acked = true }
    msg.define_singleton_method(:nak) { @nacked = true } # nats-pure uses :nak
    msg.define_singleton_method(:nack) { @nacked = true } # alias for clarity
    msg.define_singleton_method(:acked?) { @acked }
    msg.define_singleton_method(:nacked?) { @nacked }
    msg
  end

  def build_fake_connection(messages)
    sub = Object.new
    sub.instance_variable_set(:@messages, messages.dup)
    sub.define_singleton_method(:next_msg) do |timeout: 1|
      @messages.shift # nil when empty -> caller treats as drain
    end
    sub.define_singleton_method(:unsubscribe) {}

    js = Object.new
    js.define_singleton_method(:pull_subscribe) { |_subject, _durable, **_opts| sub }
    js.define_singleton_method(:subscribe) { |_subject, **_opts| sub }

    fake = Object.new
    fake.define_singleton_method(:jetstream) { js }
    fake.define_singleton_method(:close) {}
    fake.define_singleton_method(:closed?) { false }
    fake
  end
end
